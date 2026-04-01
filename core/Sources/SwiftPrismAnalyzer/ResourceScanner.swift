import Foundation

struct ResourceScanner {

    let workspaceRoot: String

    func scan() -> [ResourceNode] {
        let fileManager = FileManager.default
        var resources: [ResourceNode] = []
        var seen: Set<String> = []

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
                        filePath: path
                    ))
                }
                resources.append(contentsOf: scanAssetCatalog(at: url, catalogName: catalogName, seen: &seen))
                enumerator.skipDescendants()
                continue
            }

            guard let resourceType = classifyFile(url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let id = "file:\(name).\(url.pathExtension)"
            if seen.insert(id).inserted {
                resources.append(ResourceNode(
                    id: id,
                    name: name,
                    resourceType: resourceType,
                    catalogName: nil,
                    filePath: path
                ))
            }
        }

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
            if seen.insert(id).inserted {
                results.append(ResourceNode(
                    id: id,
                    name: assetName,
                    resourceType: assetType,
                    catalogName: catalogName,
                    filePath: url.path
                ))
            }
            enumerator.skipDescendants()
        }

        return results
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
        default: return nil
        }
    }

    private func shouldSkip(_ path: String) -> Bool {
        let skipDirs = [".build", "Build", "DerivedData", "Pods", ".swiftpm", "node_modules", ".git"]
        for dir in skipDirs {
            if path.contains("/\(dir)/") || path.hasSuffix("/\(dir)") { return true }
        }
        return false
    }
}
