import AppKit
import Foundation

/// Backend plugin = installable CLI whose `main` writes SoT under `.swiftprism/`.
struct BackendPlugin: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var binaryURL: URL

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }
}

enum BackendRegistry {
    static func swiftPlugin() -> BackendPlugin {
        BackendPlugin(name: "swift", binaryURL: DemoPaths.installedSwiftBackend)
    }

    /// Copy analyzer binary into Application Support (like installing a plugin).
    @discardableResult
    static func installSwiftBackend(from source: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let dest = DemoPaths.installedSwiftBackend
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let candidates: [URL] = [
            source,
            DemoPaths.bundledAnalyzerCandidate,
            DemoPaths.swiftPrismRepo.appendingPathComponent("core/.build/release/swift-prism-analyzer"),
        ].compactMap { $0 }

        guard let src = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw BackendError.analyzerNotFound
        }

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: src, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }
}

enum BackendError: LocalizedError {
    case analyzerNotFound
    case analyzeFailed(String)
    case noSwiftFiles

    var errorDescription: String? {
        switch self {
        case .analyzerNotFound:
            return "Swift backend binary not found. Build core/ first (swift build -c release) or open the swift-prism repo."
        case .analyzeFailed(let msg):
            return "Backend failed: \(msg)"
        case .noSwiftFiles:
            return "No .swift files in this project."
        }
    }
}

/// Runs backend `main` → writes SoT JSON (and optional SQLite via node helper).
enum BackendRunner {
    static func pickProjectFolder(start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a Swift project to open"
        panel.prompt = "Open"
        if let start { panel.directoryURL = start }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Invoke installed (or candidate) swift backend to refresh SoT for `projectRoot`.
    static func analyzeSwiftProject(_ projectRoot: URL) throws -> URL {
        let fm = FileManager.default
        if !BackendRegistry.swiftPlugin().isInstalled {
            try BackendRegistry.installSwiftBackend()
        }
        let bin = DemoPaths.installedSwiftBackend
        guard fm.isExecutableFile(atPath: bin.path) else {
            throw BackendError.analyzerNotFound
        }

        let sotDir = projectRoot.appendingPathComponent(".swiftprism", isDirectory: true)
        try fm.createDirectory(at: sotDir, withIntermediateDirectories: true)
        let gitignore = sotDir.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: gitignore.path) {
            try "*\n".write(to: gitignore, atomically: true, encoding: .utf8)
        }
        let jsonOut = sotDir.appendingPathComponent("prism-context.json")

        let swiftFiles = swiftSources(in: projectRoot)
        guard !swiftFiles.isEmpty else { throw BackendError.noSwiftFiles }

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [
            "--workspace", projectRoot.path,
            "--scan-targets",
            "--public-only-external",
            "--context",
            "--output", jsonOut.path,
        ] + swiftFiles.map(\.path)
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw BackendError.analyzeFailed(err.isEmpty ? "exit \(proc.terminationStatus)" : err)
        }

        // Best-effort SQLite SoT (Node helper from mcp-server).
        _ = try? importSQLite(from: jsonOut, sotDir: sotDir)

        // Config for MCP / UI discovery
        let config = sotDir.appendingPathComponent("swiftprism-config.json")
        let cfg: [String: String] = [
            "graphPath": jsonOut.path,
            "sqlitePath": sotDir.appendingPathComponent("graph.sqlite").path,
            "projectRoot": projectRoot.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: config, options: .atomic)

        return jsonOut
    }

    private static func swiftSources(in root: URL) -> [URL] {
        let skip = [".build", "DerivedData", "Pods", "node_modules", ".git", ".swiftprism", "Carthage"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            if skip.contains(where: { url.pathComponents.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "swift" {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func importSQLite(from json: URL, sotDir: URL) throws -> URL {
        let db = sotDir.appendingPathComponent("graph.sqlite")
        let helper = DemoPaths.swiftPrismRepo
            .appendingPathComponent("mcp-server/dist/graph-db.js")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            return db
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["node", helper.path, "import", json.path, db.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return db
    }
}
