import Foundation
import SwiftSyntax
import SwiftParser

enum RunMode {
    case analyze
    case context
    case findDependents(String)
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { throw PrismError.noInputPaths }

    var workspaceRoot: String?
    var filePaths: [String] = []
    var mode: RunMode = .analyze
    var outputPath: String?
    var scanTargets = false
    var publicOnlyExternal = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--workspace" where i + 1 < args.count:
            workspaceRoot = args[i + 1]; i += 2
        case "--context":
            mode = .context; i += 1
        case "--find-dependents-of" where i + 1 < args.count:
            mode = .findDependents(args[i + 1]); i += 2
        case "--output" where i + 1 < args.count:
            outputPath = args[i + 1]; i += 2
        case "--scan-targets":
            scanTargets = true; i += 1
        case "--public-only-external":
            publicOnlyExternal = true; i += 1
        default:
            filePaths.append(args[i]); i += 1
        }
    }

    if filePaths.isEmpty && workspaceRoot == nil {
        throw PrismError.noInputPaths
    }

    var targets: [ParsedTarget] = []
    var publicOnlyTargets: Set<String> = []

    if scanTargets || (filePaths.isEmpty && workspaceRoot != nil) {
        if let root = workspaceRoot {
            emitProgress(phase: "targets", processed: 0, total: 1)
            let resolver = TargetResolver(workspaceRoot: root)
            targets = resolver.resolve()
            emitProgress(phase: "targets", processed: 1, total: 1)

            if filePaths.isEmpty {
                filePaths = targets.flatMap(\.sourcePaths)
            }

            if publicOnlyExternal {
                for target in targets {
                    if resolver.shouldIndexPublicOnly(targetName: target.name, targets: targets) {
                        publicOnlyTargets.insert(target.name)
                    }
                }
            }
        }
    }

    var (allSymbols, fileSources) = scanFiles(filePaths)

    if !targets.isEmpty, let root = workspaceRoot {
        let resolver = TargetResolver(workspaceRoot: root)
        for idx in allSymbols.indices {
            allSymbols[idx].targetName = resolver.mapFileToTarget(allSymbols[idx].location.file, targets: targets)
        }
    }

    let resources = scanResources(workspaceRoot: workspaceRoot)

    emitProgress(phase: "macros", processed: 0, total: 1)
    var allMacros: [MacroInfo] = []
    for (filePath, tree) in fileSources {
        let macroCollector = MacroCollector(filePath: filePath)
        macroCollector.walk(tree)
        var collected = macroCollector.macros
        if !targets.isEmpty, let root = workspaceRoot {
            let resolver = TargetResolver(workspaceRoot: root)
            for idx in collected.indices {
                collected[idx].targetName = resolver.mapFileToTarget(filePath, targets: targets)
            }
        }
        allMacros.append(contentsOf: collected)
    }
    emitProgress(phase: "macros", processed: 1, total: 1)

    emitProgress(phase: "resolving", processed: 0, total: 1)
    let resolver = DependencyResolver(
        fileSources: fileSources,
        symbols: allSymbols,
        resources: resources,
        targets: targets,
        macros: allMacros,
        publicOnlyTargets: publicOnlyTargets
    )
    let result = resolver.resolve()

    switch mode {
    case .analyze:
        let json = try encodeToJSON(result)
        writeOutput(json, to: outputPath)

    case .context:
        let signaturesByFile = collectSignatures(filePaths: filePaths, fileSources: fileSources)
        let generator = ContextGenerator(analysisResult: result, signaturesByFile: signaturesByFile)
        let context = generator.generate()
        let json = try encodeToJSON(context)
        writeOutput(json, to: outputPath)

    case .findDependents(let targetId):
        let signaturesByFile = collectSignatures(filePaths: filePaths, fileSources: fileSources)
        let generator = ContextGenerator(analysisResult: result, signaturesByFile: signaturesByFile)
        let dependents = generator.generateDependentsOf(targetId)
        let json = try encodeToJSON(dependents)
        writeOutput(json, to: outputPath)
    }

    emitProgress(phase: "complete", processed: 1, total: 1)
}

func scanFiles(_ filePaths: [String]) -> ([SymbolInfo], [(path: String, tree: SourceFileSyntax)]) {
    var allSymbols: [SymbolInfo] = []
    var fileSources: [(path: String, tree: SourceFileSyntax)] = []
    let totalFiles = filePaths.count
    var processedFiles = 0

    emitProgress(phase: "scanning", processed: 0, total: totalFiles)

    for path in filePaths {
        guard let data = FileManager.default.contents(atPath: path),
              let source = String(data: data, encoding: .utf8) else {
            emitWarning("Skipping unreadable file: \(path)")
            processedFiles += 1
            continue
        }

        let tree = Parser.parse(source: source)
        fileSources.append((path: path, tree: tree))

        let collector = SymbolCollector(filePath: path)
        collector.walk(tree)
        allSymbols.append(contentsOf: collector.symbols)

        processedFiles += 1
        emitProgress(phase: "scanning", processed: processedFiles, total: totalFiles)
    }

    return (allSymbols, fileSources)
}

func scanResources(workspaceRoot: String?) -> [ResourceNode] {
    emitProgress(phase: "resources", processed: 0, total: 1)
    guard let root = workspaceRoot else {
        emitProgress(phase: "resources", processed: 1, total: 1)
        return []
    }
    let scanner = ResourceScanner(workspaceRoot: root)
    let resources = scanner.scan()
    emitProgress(phase: "resources", processed: 1, total: 1)
    return resources
}

func collectSignatures(filePaths: [String], fileSources: [(path: String, tree: SourceFileSyntax)]) -> [String: [SignatureInfo]] {
    var signaturesByFile: [String: [SignatureInfo]] = [:]
    for (path, tree) in fileSources {
        let collector = SignatureCollector(filePath: path)
        collector.walk(tree)
        signaturesByFile[path] = collector.signatures
    }
    return signaturesByFile
}

func encodeToJSON<T: Encodable>(_ value: T) throws -> String {
    emitProgress(phase: "encoding", processed: 0, total: 1)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value),
          let json = String(data: data, encoding: .utf8) else {
        throw PrismError.encodingFailed
    }
    return json
}

func writeOutput(_ json: String, to outputPath: String?) {
    if let outputPath {
        do {
            try json.write(toFile: outputPath, atomically: true, encoding: .utf8)
            fputs("{\"_info\":\"Written to \(outputPath)\"}\n", stderr)
        } catch {
            fputs("{\"_error\":\"Failed to write to \(outputPath): \(error)\"}\n", stderr)
            print(json)
        }
    } else {
        print(json)
    }
}

func emitProgress(phase: String, processed: Int, total: Int) {
    let msg = "{\"_progress\":{\"phase\":\"\(phase)\",\"processed\":\(processed),\"total\":\(total)}}"
    fputs(msg + "\n", stderr)
}

func emitWarning(_ message: String) {
    let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
    fputs("{\"_warning\":\"\(escaped)\"}\n", stderr)
}

do {
    try run()
} catch {
    fputs("{\"_error\":\"\(error)\"}\n", stderr)
    exit(1)
}
