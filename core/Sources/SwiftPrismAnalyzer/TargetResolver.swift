import Foundation

struct TargetResolver {

    let workspaceRoot: String

    func resolve() -> [ParsedTarget] {
        let packageSwift = (workspaceRoot as NSString).appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: packageSwift) {
            return resolvePackageTargets()
        }

        let xcodeproj = findFirstMatch(extension: "xcodeproj")
        let xcworkspace = findFirstMatch(extension: "xcworkspace")
        if xcodeproj != nil || xcworkspace != nil {
            return resolveXcodeProject()
        }

        return resolveStandaloneFiles()
    }

    func mapFileToTarget(_ filePath: String, targets: [ParsedTarget]) -> String? {
        for target in targets {
            if filePath.hasPrefix(target.path + "/") || filePath == target.path {
                return target.name
            }
            for sourcePath in target.sourcePaths {
                if filePath == sourcePath {
                    return target.name
                }
            }
        }
        return nil
    }

    func shouldIndexPublicOnly(targetName: String, targets: [ParsedTarget]) -> Bool {
        guard let target = targets.first(where: { $0.name == targetName }) else { return false }
        return target.type == .library && isExternalDependency(target)
    }

    private func resolvePackageTargets() -> [ParsedTarget] {
        let parser = PackageManifestParser(packagePath: workspaceRoot)
        var targets = parser.parse()

        let localPackages = discoverLocalPackages()
        for pkgPath in localPackages {
            let subParser = PackageManifestParser(packagePath: pkgPath)
            let subTargets = subParser.parse()
            targets.append(contentsOf: subTargets)
        }

        return targets
    }

    private func resolveXcodeProject() -> [ParsedTarget] {
        var targets: [ParsedTarget] = []
        let sourcesDir = (workspaceRoot as NSString).appendingPathComponent("Sources")
        let fm = FileManager.default

        if fm.fileExists(atPath: sourcesDir) {
            let contents = (try? fm.contentsOfDirectory(atPath: sourcesDir)) ?? []
            for dir in contents {
                let fullPath = (sourcesDir as NSString).appendingPathComponent(dir)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
                targets.append(ParsedTarget(
                    name: dir,
                    type: .library,
                    path: fullPath,
                    sourcePaths: discoverSwiftFiles(in: fullPath),
                    dependencies: []
                ))
            }
        }

        let swiftFiles = discoverSwiftFiles(in: workspaceRoot)
            .filter { !$0.contains("/Sources/") && !$0.contains("/Tests/") && !$0.contains("/.build/") }
        if !swiftFiles.isEmpty {
            targets.append(ParsedTarget(
                name: inferProjectName(),
                type: .executable,
                path: workspaceRoot,
                sourcePaths: swiftFiles,
                dependencies: []
            ))
        }

        return targets
    }

    private func resolveStandaloneFiles() -> [ParsedTarget] {
        let swiftFiles = discoverSwiftFiles(in: workspaceRoot)
        guard !swiftFiles.isEmpty else { return [] }
        return [ParsedTarget(
            name: inferProjectName(),
            type: .unknown,
            path: workspaceRoot,
            sourcePaths: swiftFiles,
            dependencies: []
        )]
    }

    private func discoverLocalPackages() -> [String] {
        let fm = FileManager.default
        var packages: [String] = []
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: workspaceRoot),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            let path = url.path
            if shouldSkip(path) {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == "Package.swift" && url.path != (workspaceRoot as NSString).appendingPathComponent("Package.swift") {
                packages.append(url.deletingLastPathComponent().path)
                enumerator.skipDescendants()
            }
        }
        return packages
    }

    private func discoverSwiftFiles(in directory: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let path = url.path
            if shouldSkip(path) {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "swift" {
                files.append(path)
            }
        }
        return files.sorted()
    }

    private func findFirstMatch(extension ext: String) -> String? {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: workspaceRoot)) ?? []
        return contents.first { ($0 as NSString).pathExtension == ext }
    }

    private func inferProjectName() -> String {
        URL(fileURLWithPath: workspaceRoot).lastPathComponent
    }

    private func isExternalDependency(_ target: ParsedTarget) -> Bool {
        target.path.contains(".build/checkouts") || target.path.contains("SourcePackages")
    }

    private func shouldSkip(_ path: String) -> Bool {
        let skipDirs = [".build", "Build", "DerivedData", "Pods", ".swiftpm", "node_modules", ".git", "Carthage"]
        for dir in skipDirs {
            if path.contains("/\(dir)/") || path.hasSuffix("/\(dir)") { return true }
        }
        return false
    }
}
