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
        if let pbxTargets = parseXcodeProj() {
            return pbxTargets
        }

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

    private func parseXcodeProj() -> [ParsedTarget]? {
        let fm = FileManager.default
        guard let projDir = findFirstMatch(extension: "xcodeproj") else { return nil }
        let pbxPath = (workspaceRoot as NSString)
            .appendingPathComponent(projDir)
            .appending("/project.pbxproj")

        guard let data = fm.contents(atPath: pbxPath),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let targetPattern = try? NSRegularExpression(
            pattern: #"/\* (.+?) \*/ = \{[^}]*isa = PBXNativeTarget;[^}]*productName = "?([^";]+)"?;[^}]*\}"#,
            options: [.dotMatchesLineSeparators]
        )
        let fileRefPattern = try? NSRegularExpression(
            pattern: #"[A-F0-9]+ /\* (.+?\.swift) \*/"#,
            options: []
        )

        guard let targetRegex = targetPattern, let fileRegex = fileRefPattern else { return nil }

        let targetSectionPattern = try? NSRegularExpression(
            pattern: #"([A-F0-9]+) /\* (.+?) \*/ = \{\s*isa = PBXNativeTarget;\s*.*?buildPhases = \((.*?)\);\s*.*?name = "?([^";]+)"?;"#,
            options: [.dotMatchesLineSeparators]
        )

        var targetNames: [String] = []
        let simpleTargetPattern = try? NSRegularExpression(
            pattern: #"name = "?([^";]+)"?;\s*[^}]*productType = "com\.apple\.\w+";"#,
            options: [.dotMatchesLineSeparators]
        )

        if let regex = simpleTargetPattern {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    targetNames.append(String(content[range]))
                }
            }
        }

        if targetNames.isEmpty {
            targetNames = [inferProjectName()]
        }

        let allSwiftFiles = discoverSwiftFiles(in: workspaceRoot)

        if targetNames.count == 1 {
            let name = targetNames[0]
            return [ParsedTarget(
                name: name,
                type: .executable,
                path: workspaceRoot,
                sourcePaths: allSwiftFiles,
                dependencies: []
            )]
        }

        var targets: [ParsedTarget] = []
        for name in targetNames {
            let targetDir = (workspaceRoot as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: targetDir, isDirectory: &isDir), isDir.boolValue {
                targets.append(ParsedTarget(
                    name: name,
                    type: .library,
                    path: targetDir,
                    sourcePaths: discoverSwiftFiles(in: targetDir),
                    dependencies: []
                ))
            }
        }

        let assignedFiles = Set(targets.flatMap(\.sourcePaths))
        let unassigned = allSwiftFiles.filter { !assignedFiles.contains($0) }
        if !unassigned.isEmpty {
            let mainTarget = targetNames.first ?? inferProjectName()
            if let idx = targets.firstIndex(where: { $0.name == mainTarget }) {
                var t = targets[idx]
                targets[idx] = ParsedTarget(
                    name: t.name, type: .executable, path: t.path,
                    sourcePaths: t.sourcePaths + unassigned, dependencies: t.dependencies
                )
            } else {
                targets.append(ParsedTarget(
                    name: mainTarget,
                    type: .executable,
                    path: workspaceRoot,
                    sourcePaths: unassigned,
                    dependencies: []
                ))
            }
        }

        return targets.isEmpty ? nil : targets
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

    func isExternalDependency(_ target: ParsedTarget) -> Bool {
        target.isExternal || target.path.contains(".build/checkouts") || target.path.contains("SourcePackages") || target.path.contains("Pods/")
    }

    private func shouldSkip(_ path: String) -> Bool {
        let skipDirs = [".build", "Build", "DerivedData", "Pods", ".swiftpm", "node_modules", ".git", "Carthage"]
        for dir in skipDirs {
            if path.contains("/\(dir)/") || path.hasSuffix("/\(dir)") { return true }
        }
        return false
    }
}
