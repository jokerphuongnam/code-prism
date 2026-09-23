import Foundation

struct ResourceScanner {

    let workspaceRoot: String

    func scan() -> [ResourceNode] {
        let fileManager = FileManager.default
        var resources: [ResourceNode] = []
        var seen: Set<String> = []
        var standaloneFiles: [ResourceNode] = []

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: workspaceRoot),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return resources }

        while let url = enumerator.nextObject() as? URL {
            let path = url.path

            if shouldSkip(path) {
                enumerator.skipDescendants()
                continue
            }

            if url.pathExtension == "xcassets" {
                let catalogName = url.deletingPathExtension().lastPathComponent
                let catalogId = "catalog:\(catalogName)"
                if seen.insert(catalogId).inserted {
                    resources.append(ResourceNode(
                        id: catalogId,
                        name: catalogName,
                        resourceType: .assetCatalog,
                        catalogName: nil,
                        parentGroup: nil,
                        filePath: path
                    ))
                }
                resources.append(contentsOf: scanAssetCatalog(at: url, catalogName: catalogName, seen: &seen))
                enumerator.skipDescendants()
                continue
            }

            if url.pathExtension == "lproj" {
                let locName = url.deletingPathExtension().lastPathComponent
                let locId = "loc:\(locName)"
                if seen.insert(locId).inserted {
                    resources.append(ResourceNode(
                        id: locId,
                        name: "\(locName).lproj",
                        resourceType: .localization,
                        catalogName: nil,
                        parentGroup: "bundle:Localizations",
                        filePath: path
                    ))
                }
                enumerator.skipDescendants()
                continue
            }

            guard let resourceType = classifyFile(url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let id = "file:\(name).\(url.pathExtension)"
            if seen.insert(id).inserted {
                let folderName = resolveGroupName(for: url)
                let parentGroup = "bundle:\(folderName)"

                standaloneFiles.append(ResourceNode(
                    id: id,
                    name: name,
                    resourceType: resourceType,
                    catalogName: nil,
                    parentGroup: parentGroup,
                    filePath: path
                ))
            }
        }

        var bundleGroups: Set<String> = []
        for file in standaloneFiles {
            if let group = file.parentGroup, bundleGroups.insert(group).inserted {
                let groupName = String(group.dropFirst("bundle:".count))
                resources.append(ResourceNode(
                    id: group,
                    name: groupName,
                    resourceType: .otherFile,
                    catalogName: nil,
                    parentGroup: nil,
                    filePath: ""
                ))
            }
        }

        if standaloneFiles.contains(where: { $0.parentGroup == "bundle:Localizations" }) {
            if bundleGroups.insert("bundle:Localizations").inserted {
                resources.append(ResourceNode(
                    id: "bundle:Localizations",
                    name: "Localizations",
                    resourceType: .localization,
                    catalogName: nil,
                    parentGroup: nil,
                    filePath: ""
                ))
            }
        }

        resources.append(contentsOf: standaloneFiles)

        return resources
    }

    private func scanAssetCatalog(at catalogURL: URL, catalogName: String, seen: inout Set<String>) -> [ResourceNode] {
        let fileManager = FileManager.default
        var results: [ResourceNode] = []

        guard let enumerator = fileManager.enumerator(
            at: catalogURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension
            guard let assetType = classifyAssetSet(ext) else { continue }

            let assetName = url.deletingPathExtension().lastPathComponent
            let id = "asset:\(catalogName)/\(assetName)"
            let resolvedPath = resolveAssetFilePath(assetDir: url) ?? url.path
            if seen.insert(id).inserted {
                results.append(ResourceNode(
                    id: id,
                    name: assetName,
                    resourceType: assetType,
                    catalogName: catalogName,
                    parentGroup: "catalog:\(catalogName)",
                    filePath: resolvedPath
                ))
            }
            enumerator.skipDescendants()
        }

        return results
    }

    private func resolveAssetFilePath(assetDir: URL) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: assetDir, includingPropertiesForKeys: nil) else { return nil }
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "pdf", "svg", "heic", "webp"]
        let candidates = contents.filter { imageExts.contains($0.pathExtension.lowercased()) }
        let sorted = candidates.sorted { a, b in
            let aName = a.deletingPathExtension().lastPathComponent
            let bName = b.deletingPathExtension().lastPathComponent
            if aName.hasSuffix("@3x") { return true }
            if bName.hasSuffix("@3x") { return false }
            if aName.hasSuffix("@2x") { return true }
            if bName.hasSuffix("@2x") { return false }
            return aName > bName
        }
        return sorted.first?.path
    }

    private func classifyAssetSet(_ ext: String) -> ResourceType? {
        switch ext {
        case "imageset": return .imageSet
        case "colorset": return .colorSet
        case "dataset": return .dataSet
        default: return nil
        }
    }

    private func classifyFile(_ url: URL) -> ResourceType? {
        switch url.pathExtension.lowercased() {
        case "json": return .jsonFile
        case "plist": return .plistFile
        case "md", "markdown": return .markdownFile
        case "strings", "stringsdict": return .stringsFile
        default: return nil
        }
    }

    private func resolveGroupName(for url: URL) -> String {
        let parentDir = url.deletingLastPathComponent().lastPathComponent
        let knownGroups: Set<String> = ["Resources", "Supporting Files", "Config", "Configuration"]
        if knownGroups.contains(parentDir) { return parentDir }
        if parentDir == URL(fileURLWithPath: workspaceRoot).lastPathComponent { return "Resources" }
        return parentDir
    }

    private func shouldSkip(_ path: String) -> Bool {
        let skipDirs = [".build", "Build", "DerivedData", "Pods", ".swiftpm", "node_modules", ".git", "Carthage"]
        for dir in skipDirs {
            if path.contains("/\(dir)/") || path.hasSuffix("/\(dir)") { return true }
        }
        return false
    }
}
