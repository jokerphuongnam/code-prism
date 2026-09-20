import Foundation

enum DemoPaths {
    /// Default sample project (clear View/Model graph).
    static var liteTrace: URL {
        URL(fileURLWithPath: NSString("~/Documents/Code/iOS/LiteTrace").expandingTildeInPath)
    }

    static var swiftPrismRepo: URL {
        // app/Sources/... → walk up to repo root (app/)
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // SwiftPrismApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // app
    }

    static var bundledAnalyzerCandidate: URL {
        swiftPrismRepo
            .appendingPathComponent("extension/bin/swift-prism-analyzer")
    }

    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SwiftPrism", isDirectory: true)
    }

    static var backendsRoot: URL {
        supportRoot.appendingPathComponent("backends", isDirectory: true)
    }

    static var installedSwiftBackend: URL {
        backendsRoot.appendingPathComponent("swift/swift-prism-analyzer")
    }
}
