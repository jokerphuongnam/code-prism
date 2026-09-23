import Foundation

struct PrismContext: Encodable {
    let version: String
    let generatedAt: String
    let projectType: String
    let targets: [TargetSummary]
    let files: [FileContext]
    let assetMap: [AssetUsage]
    let macroMap: [MacroSummary]
    let dependencyIndex: [String: [String]]
}

struct TargetSummary: Encodable {
    let name: String
    let type: String
    let fileCount: Int
    let dependencies: [String]
}

struct MacroSummary: Encodable {
    let name: String
    let type: String
    let role: String?
    let appliedTo: [String]
}

struct FileContext: Encodable {
    let path: String
    let target: String?
    let signatures: [SignatureEntry]
}

struct SignatureEntry: Encodable {
    let id: String
    let signature: String
    let line: Int
    let dependencies: [String]
    let resources: [String]
}

struct AssetUsage: Encodable {
    let assetId: String
    let assetName: String
    let assetType: String
    let usedBy: [String]
}

struct ContextGenerator {

    let analysisResult: AnalysisResult
    let signaturesByFile: [String: [SignatureInfo]]

    func generate() -> PrismContext {
        let outgoingLinks = buildOutgoingLinks()
        let resourceLinks = buildResourceLinks()
        let assetMap = buildAssetMap()
        let dependencyIndex = buildDependencyIndex()

        let targetMap = buildFileTargetMap()

        let files: [FileContext] = signaturesByFile.keys.sorted().map { filePath in
            let sigs = signaturesByFile[filePath] ?? []
            let entries = sigs.map { sig -> SignatureEntry in
                let deps = outgoingLinks[sig.id] ?? []
                let resources = resourceLinks[sig.id] ?? []
                return SignatureEntry(id: sig.id, signature: sig.signature, line: sig.line, dependencies: deps.sorted(), resources: resources.sorted())
            }
            return FileContext(path: filePath, target: targetMap[filePath], signatures: entries)
        }

        let targetSummaries = analysisResult.targets.map { t in
            let fileCount = signaturesByFile.keys.filter { path in
                targetMap[path] == t.name
            }.count
            return TargetSummary(name: t.name, type: t.type.rawValue, fileCount: fileCount, dependencies: t.dependencies)
        }

        let macroSummaries = buildMacroSummaries()

        let projectType = detectProjectType()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return PrismContext(
            version: "2.0",
            generatedAt: formatter.string(from: Date()),
            projectType: projectType,
            targets: targetSummaries,
            files: files,
            assetMap: assetMap,
            macroMap: macroSummaries,
            dependencyIndex: dependencyIndex
        )
    }

    func generateDependentsOf(_ targetId: String) -> [String: [String]] {
        var result: [String: [String]] = ["direct": [], "transitive": [], "files": [], "resources": [], "targets": []]

        let directDeps = analysisResult.links
            .filter { $0.sourceId == targetId }
            .map(\.targetId)

        let directCallers = analysisResult.links
            .filter { $0.targetId == targetId }
            .map(\.sourceId)

        result["direct"] = (directDeps + directCallers).sorted()

        var transitive: Set<String> = []
        var frontier = Set(directDeps + directCallers)
        var visited: Set<String> = [targetId]

        for _ in 0..<3 {
            var nextFrontier: Set<String> = []
            for node in frontier where !visited.contains(node) {
                visited.insert(node)
                let neighbors = analysisResult.links
                    .filter { $0.sourceId == node || $0.targetId == node }
                    .flatMap { [$0.sourceId, $0.targetId] }
                    .filter { !visited.contains($0) }
                transitive.formUnion(neighbors)
                nextFrontier.formUnion(neighbors)
            }
            frontier = nextFrontier
        }
        transitive.subtract(Set(directDeps + directCallers))
        transitive.remove(targetId)
        result["transitive"] = transitive.sorted()

        let allRelated = Set(directDeps + directCallers).union(transitive).union([targetId])
        let files = Set(
            analysisResult.nodes
                .filter { allRelated.contains($0.id) }
                .map(\.location.file)
        )
        result["files"] = files.sorted()

        let resources = analysisResult.links
            .filter { allRelated.contains($0.sourceId) && ($0.type == .resourceLink || $0.type == .resourceAlias || $0.type == .heuristicLink) }
            .map(\.targetId)
        result["resources"] = Array(Set(resources)).sorted()

        let relatedTargets = Set(
            analysisResult.nodes
                .filter { allRelated.contains($0.id) }
                .compactMap(\.targetName)
        )
        result["targets"] = relatedTargets.sorted()

        return result
    }

    private func buildFileTargetMap() -> [String: String] {
        var map: [String: String] = [:]
        for node in analysisResult.nodes {
            if let target = node.targetName {
                map[node.location.file] = target
            }
        }
        return map
    }

    private func buildMacroSummaries() -> [MacroSummary] {
        let macroExpansions = analysisResult.links.filter { $0.type == .macroExpansion }
        var appliedMap: [String: [String]] = [:]
        for link in macroExpansions {
            appliedMap[link.sourceId, default: []].append(link.targetId)
        }

        return analysisResult.macros.map { m in
            MacroSummary(
                name: m.name,
                type: m.macroType.rawValue,
                role: m.role?.rawValue,
                appliedTo: appliedMap[m.name]?.sorted() ?? []
            )
        }
    }

    private func detectProjectType() -> String {
        if !analysisResult.macros.isEmpty && analysisResult.targets.contains(where: { $0.type == .macroTarget }) {
            return "swift_macro_package"
        }
        if analysisResult.targets.count > 1 {
            return "multi_target_package"
        }
        if analysisResult.targets.first?.type == .library {
            return "swift_package"
        }
        if analysisResult.targets.first?.type == .executable {
            return "swift_app"
        }
        return "standalone"
    }

    private func buildOutgoingLinks() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for link in analysisResult.links where link.type == .call || link.type == .access || link.type == .crossTargetDependency {
            map[link.sourceId, default: []].append(link.targetId)
        }
        return map
    }

    private func buildResourceLinks() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for link in analysisResult.links where link.type == .resourceLink || link.type == .resourceAlias || link.type == .heuristicLink {
            map[link.sourceId, default: []].append(link.targetId)
        }
        return map
    }

    private func buildAssetMap() -> [AssetUsage] {
        var usageMap: [String: Set<String>] = [:]
        for link in analysisResult.links where link.type == .resourceLink || link.type == .resourceAlias || link.type == .heuristicLink {
            usageMap[link.targetId, default: []].insert(link.sourceId)
        }

        return analysisResult.resources.compactMap { resource in
            let users = usageMap[resource.id]
            guard let users, !users.isEmpty else { return nil }
            return AssetUsage(
                assetId: resource.id,
                assetName: resource.name,
                assetType: resource.resourceType.rawValue,
                usedBy: users.sorted()
            )
        }.sorted { $0.assetName < $1.assetName }
    }

    private func buildDependencyIndex() -> [String: [String]] {
        var index: [String: Set<String>] = [:]
        for link in analysisResult.links {
            index[link.sourceId, default: []].insert(link.targetId)
            index[link.targetId, default: []].insert(link.sourceId)
        }
        return index.mapValues { $0.sorted() }
    }
}
