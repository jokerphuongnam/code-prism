import Foundation
import SwiftSyntax
import SwiftParser

enum RunMode {
    case analyze
    case context
    case findDependents(String)
    case fullSummary
    case focus(String)
    case directScan(projectPath: String, outputPath: String)
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { throw PrismError.noInputPaths }

    if let mode = detectDirectScanMode(args) {
        try runDirectScan(mode)
        return
    }

    try runFlagMode(args)
}

func detectDirectScanMode(_ args: [String]) -> RunMode? {
    guard args.count == 2 else { return nil }
    let first = args[0]
    let second = args[1]
    guard !first.hasPrefix("-") && !second.hasPrefix("-") else { return nil }
    guard second.hasSuffix(".json") else { return nil }
    return .directScan(projectPath: first, outputPath: second)
}

func runDirectScan(_ mode: RunMode) throws {
    guard case .directScan(let projectPath, let outputPath) = mode else { return }

    let fm = FileManager.default
    let resolvedPath = (projectPath as NSString).standardizingPath
    var isDir: ObjCBool = false

    guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue else {
        throw PrismError.directoryInaccessible(resolvedPath)
    }

    guard fm.isReadableFile(atPath: resolvedPath) else {
        throw PrismError.directoryInaccessible(resolvedPath)
    }

    emitProgress(phase: "scanning", processed: 0, total: 0)

    let targetResolver = TargetResolver(workspaceRoot: resolvedPath)
    let targets = targetResolver.resolve()

    var swiftFiles = discoverSwiftFiles(in: resolvedPath)
    if swiftFiles.isEmpty && !targets.isEmpty {
        swiftFiles = targets.flatMap(\.sourcePaths)
    }
    guard !swiftFiles.isEmpty else {
        throw PrismError.noSwiftFilesFound(resolvedPath)
    }

    var (allSymbols, fileSources, fileImports, extLocs) = scanFiles(swiftFiles, targets: targets, targetResolver: targetResolver)

    for idx in allSymbols.indices {
        if allSymbols[idx].targetName == nil {
            allSymbols[idx].targetName = targetResolver.mapFileToTarget(allSymbols[idx].location.file, targets: targets)
        }
    }

    let projectName = sanitizeTargetName(URL(fileURLWithPath: resolvedPath).lastPathComponent)
    for idx in allSymbols.indices {
        if allSymbols[idx].targetName == nil {
            allSymbols[idx].targetName = sanitizeTargetName(targets.first?.name ?? projectName)
        } else {
            allSymbols[idx].targetName = sanitizeTargetName(allSymbols[idx].targetName!)
        }
    }

    let resources = scanResources(workspaceRoot: resolvedPath)

    emitProgress(phase: "resolving", processed: 0, total: 1)

    let resolvedURLs = parsePackageResolved(workspaceRoot: resolvedPath)

    let depResolver = DependencyResolver(
        fileSources: fileSources,
        symbols: allSymbols,
        resources: resources,
        targets: targets,
        macros: [],
        publicOnlyTargets: [],
        fileImports: fileImports,
        projectRoot: resolvedPath,
        resolvedURLs: resolvedURLs
    )
    let result = depResolver.resolve()

    var flatEntries = convertToFlatMap(result, fileImportsMap: fileImports, extensionLocations: extLocs)

    // ── Semantic Context Enrichment ──
    // Generate token-optimized contexts for each eligible node via local LLM or fallback.
    // Cache directory defaults to .swiftprism next to the output file.
    let semanticCacheDir = ((outputPath as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent(".swiftprism")
    emitProgress(phase: "semantic_context", processed: 0, total: flatEntries.count)
    let semanticGen = SemanticContextGenerator(
        fileSources: fileSources, cacheDir: semanticCacheDir
    )
    let semanticStats = semanticGen.enrich(&flatEntries)
    emitProgress(phase: "semantic_context", processed: flatEntries.count, total: flatEntries.count)
    fputs("{\"_info\":\"Semantic context: \(semanticStats.generated) generated, \(semanticStats.cached) cached, LLM: \(semanticStats.llmUsed)\"}\n", stderr)

    let json = try safeEncodeToJSON(flatEntries, label: "FlatMapEntry")

    do {
        let outputDir = (outputPath as NSString).deletingLastPathComponent
        if !outputDir.isEmpty && !fm.fileExists(atPath: outputDir) {
            try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }
        try json.write(toFile: outputPath, atomically: true, encoding: .utf8)
    } catch {
        throw PrismError.outputWriteFailed("\(outputPath): \(error.localizedDescription)")
    }

    emitProgress(phase: "complete", processed: 1, total: 1)
    fputs("{\"_info\":\"Written \(flatEntries.count) entries to \(outputPath)\"}\n", stderr)
}

func collectImportedModules(from result: AnalysisResult) -> Set<String> {
    var modules = Set<String>()
    for node in result.nodes {
        if let target = node.targetName {
            modules.insert(target)
        }
    }
    for target in result.targets {
        modules.insert(target.name)
        for dep in target.dependencies {
            modules.insert(dep)
        }
    }
    return modules
}

func sanitizeTargetName(_ name: String) -> String {
    let suffixes = ["_iOS", "_macOS", "_tvOS", "_watchOS", "_visionOS", "-iOS", "-macOS"]
    var result = name
    for suffix in suffixes {
        if result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
            break
        }
    }
    return result
}

func convertToFlatMap(_ result: AnalysisResult, fileImportsMap: [String: [String]] = [:], extensionLocations: [String: [SourceLocation]] = [:]) -> [FlatMapEntry] {
    let objectFlavors: Set<String> = ["struct", "class", "enum", "actor", "protocol"]

    var outgoing: [String: [String]] = [:]
    let callLinkTypes: Set<LinkType> = [.call, .access, .observerTrigger, .crossTargetDependency, .importDependency]
    for link in result.links where callLinkTypes.contains(link.type) {
        outgoing[link.sourceId, default: []].append(link.targetId)
    }

    // Build set of target node IDs for identity checks
    let targetNodeIds = Set(result.nodes.filter { $0.flavor == .target }.map(\.id))

    var inheritanceMap: [String: String] = [:]
    var conformanceMap: [String: [String]] = [:]
    for link in result.links {
        if link.type == .inheritance {
            if inheritanceMap[link.sourceId] == nil {
                inheritanceMap[link.sourceId] = link.targetId
            }
        }
        if link.type == .conformance {
            conformanceMap[link.sourceId, default: []].append(link.targetId)
        }
    }

    // Collect holds_type links → stores map (Object → [referenced type/target IDs])
    var storageMap: [String: [String]] = [:]
    for link in result.links where link.type == .holdsType {
        storageMap[link.sourceId, default: []].append(link.targetId)
    }

    // Phase 1: Build Virtual Symbol Map from analyzed nodes (internal symbols)
    var virtualSymbolMap: [String: String] = [:]
    for node in result.nodes {
        if objectFlavors.contains(node.flavor.rawValue) {
            virtualSymbolMap[node.name] = sanitizeTargetName(node.targetName ?? "")
        }
    }

    // Phase 2: Build import-to-module map from source files
    let importedModules = collectImportedModules(from: result)
    let internalModuleNames = Set(result.targets.map { sanitizeTargetName($0.name) })
    let externalModules = importedModules.subtracting(internalModuleNames).subtracting(["Swift", "Foundation"])

    var typeToTarget: [String: String] = [:]
    let swiftPrimitives: Set<String> = ["Int", "String", "Bool", "Double", "Float", "Void", "Any", "Error", "Array", "Dictionary", "Set", "Optional", "Result", "Never", "AnyObject", "AnyHashable"]

    // Level 3: Internal symbols from Virtual Symbol Map
    for (typeName, target) in virtualSymbolMap {
        typeToTarget[typeName] = target
    }

    // Level 1: Swift primitives
    for prim in swiftPrimitives {
        typeToTarget[prim] = "Swift"
    }

    let symbolById: [String: Node] = Dictionary(result.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let externalTargetNames = Set(result.targets.filter(\.isExternal).map(\.name))
    let internalTargetNames = Set(result.targets.filter { !$0.isExternal }.map(\.name))

    func filterSymbolRefs(_ ids: [String], currentTarget: String?) -> [String] {
        var filtered: [String] = []
        var seenTargets = Set<String>()
        for id in ids {
            // Target nodes pass through with their plain ID
            if targetNodeIds.contains(id) {
                if seenTargets.insert(id).inserted {
                    filtered.append(id)
                }
                continue
            }

            let sym = symbolById[id]

            // Object-flavor targets (e.g. from init calls A()) → resolve to namespaced Object ID
            if let sym, objectFlavors.contains(sym.flavor.rawValue) {
                let nsObjId = namespacedID(sym.id, target: sym.targetName)
                if seenTargets.insert(nsObjId).inserted {
                    filtered.append(nsObjId)
                }
                continue
            }

            let symTarget = sym?.targetName ?? currentTarget

            if let t = symTarget, externalTargetNames.contains(t) {
                if seenTargets.insert(t).inserted {
                    filtered.append(t)
                }
                continue
            }

            // Stored property access (a.a) → resolve to parent Object ID
            if let sym, sym.flavor.rawValue == "variable",
               (sym.subKind == .stored || sym.subKind == nil),
               let parent = sym.parent {
                let nsParent = namespacedID(parent, target: symTarget)
                if seenTargets.insert(nsParent).inserted {
                    filtered.append(nsParent)
                }
                continue
            }

            filtered.append(namespacedID(id, target: symTarget))
        }
        return filtered
    }

    func aggregateTypesToTargets(_ types: [String]?, currentTarget: String?, sourceFile: String?) -> [String]? {
        guard let types, !types.isEmpty else { return nil }
        var results: [String] = []
        var seenTargets = Set<String>()
        var seenIds = Set<String>()

        let systemFrameworks: Set<String> = ["Swift", "Foundation", "UIKit", "SwiftUI", "CoreFoundation", "CoreGraphics", "CoreData", "CoreLocation", "MapKit", "AVFoundation", "Photos", "Contacts", "EventKit", "StoreKit", "GameKit", "CloudKit", "WatchKit", "WidgetKit", "AppKit", "SceneKit", "SpriteKit", "Metal", "MetalKit", "CoreImage", "CoreText", "CoreAnimation", "QuartzCore", "Security", "CryptoKit", "os", "Dispatch", "ObjectiveC", "Darwin"]

        let contextImports = sourceFile.flatMap { fileImportsMap[$0] } ?? []
        let thirdPartyImports = contextImports.filter { !systemFrameworks.contains($0) && !internalModuleNames.contains($0) }

        for typeName in types {
            if swiftPrimitives.contains(typeName) { continue }

            var owningTarget = typeToTarget[typeName]

            if owningTarget == nil && thirdPartyImports.count == 1 {
                owningTarget = thirdPartyImports[0]
            }

            if owningTarget == nil && !thirdPartyImports.isEmpty {
                for imp in thirdPartyImports {
                    if typeName.lowercased().contains(imp.lowercased().prefix(3).description) ||
                       imp.lowercased().contains(typeName.lowercased().prefix(3).description) {
                        owningTarget = imp
                        break
                    }
                }
            }

            if owningTarget == nil {
                if !seenIds.contains(typeName) {
                    seenIds.insert(typeName)
                    results.append(typeName)
                }
                continue
            }

            if owningTarget == "Swift" { continue }

            if owningTarget == currentTarget {
                if let sym = result.nodes.first(where: { $0.name == typeName && objectFlavors.contains($0.flavor.rawValue) }) {
                    let nsId = namespacedID(sym.id, target: sym.targetName)
                    if seenIds.insert(nsId).inserted {
                        results.append(nsId)
                    }
                }
                continue
            }

            if let target = owningTarget, seenTargets.insert(target).inserted {
                results.append(target)
            }
        }
        return results.isEmpty ? nil : results
    }

    func namespacedID(_ nodeId: String, target: String?) -> String {
        let sanitizedId = nodeId.replacingOccurrences(of: ".", with: "::")
        let t = (target == nil || target!.isEmpty) ? "UnknownTarget" : target!
        return "\(t)::\(sanitizedId)"
    }

    func namespaceParent(_ parentId: String?, target: String?) -> String? {
        guard let pid = parentId else { return nil }
        return namespacedID(pid, target: target)
    }

    var entries: [FlatMapEntry] = []
    var objectEntryIndex: [String: Int] = [:]

    for node in result.nodes {
        if node.flavor == .variable && (node.subKind == .stored || node.subKind == nil) {
            continue
        }

        // Target nodes use plain name as ID, no namespacing
        let isTarget = node.flavor == .target
        let isObject = objectFlavors.contains(node.flavor.rawValue)
        let nsId = isTarget ? node.id : namespacedID(node.id, target: node.targetName)

        if isTarget {
            let rawCalls = (outgoing[node.id] ?? []).sorted()
            let filteredCalls = rawCalls.filter { targetNodeIds.contains($0) }

            var entry = FlatMapEntry(
                id: nsId,
                name: node.name,
                flavor: "target",
                location: FlatLocation(absPath: node.sourceFile, line: 0, col: 0),
                parents: []
            )
            // Internal targets (sourceFile == "") have no origin — managed by GLOBAL::MAIN
            if !node.sourceFile.isEmpty {
                entry.origin = node.sourceFile
            }
            entry.calls = filteredCalls.isEmpty ? nil : filteredCalls
            entries.append(entry)
            continue
        }

        // Non-target nodes: single lexical parent (Object ID or filename)
        let nsParent: String?
        if let parentId = node.parent {
            nsParent = namespacedID(parentId, target: node.targetName)
        } else {
            // Top-level: parent = filename (no file: prefix, no target)
            let file = node.parentFile ?? node.sourceFile
            nsParent = file.split(separator: "/").last.map(String.init) ?? file
        }
        let parents: [String] = nsParent.map { [$0] } ?? []
        let sigName = node.signature.map { "\(node.name)\($0)" } ?? node.name

        if node.flavor == .initializer {
            let nsParentId = namespacedID(node.parent ?? "", target: node.targetName)
            if let idx = objectEntryIndex[nsParentId] {
                let raw = (outgoing[node.id] ?? []).sorted()
                let filtered = filterSymbolRefs(raw, currentTarget: node.targetName)
                entries[idx].inits = (entries[idx].inits ?? []) + filtered
            }
            continue
        }

        if node.name == "deinit" && node.flavor == .function {
            let nsParentId = namespacedID(node.parent ?? "", target: node.targetName)
            if let idx = objectEntryIndex[nsParentId] {
                let raw = (outgoing[node.id] ?? []).sorted()
                let filtered = filterSymbolRefs(raw, currentTarget: node.targetName)
                entries[idx].deinits = (entries[idx].deinits ?? []) + filtered
            }
            continue
        }

        var entry = FlatMapEntry(
            id: nsId,
            name: sigName,
            flavor: node.flavor.rawValue,
            location: FlatLocation(
                absPath: node.location.file,
                line: node.location.line,
                col: node.location.column
            ),
            parents: parents
        )

        if isObject {
            // Build locations: primary declaration + extension blocks
            var locs: [FlatLocation] = []
            // Extension locations keyed by raw symbol name (not namespaced)
            if let extLocs = extensionLocations[node.name], !extLocs.isEmpty {
                for ext in extLocs {
                    locs.append(FlatLocation(absPath: ext.file, line: ext.line, col: ext.column))
                }
            }
            if !locs.isEmpty {
                entry.locations = locs
            }
            entry.inits = []
            entry.deinits = []
            entry.extends = inheritanceMap[node.id]
            entry.implements = conformanceMap[node.id]?.sorted()
            // Resolve stored property type dependencies
            if let rawStores = storageMap[node.id] {
                let resolved = filterSymbolRefs(rawStores, currentTarget: node.targetName)
                if !resolved.isEmpty {
                    entry.stores = resolved
                }
            }
            objectEntryIndex[nsId] = entries.count
        } else {
            if node.isProtocolRequirement {
                entry.calls = nil
            } else {
                let rawCalls = (outgoing[node.id] ?? []).sorted()
                entry.calls = filterSymbolRefs(rawCalls, currentTarget: node.targetName)
            }
            entry.returnTypes = aggregateTypesToTargets(node.returnTypes, currentTarget: node.targetName, sourceFile: node.sourceFile)
            entry.parameterTypes = aggregateTypesToTargets(node.parameterTypes, currentTarget: node.targetName, sourceFile: node.sourceFile)

            let frameworkTargetsInTypes = Set(
                ((entry.returnTypes ?? []) + (entry.parameterTypes ?? []))
                    .filter { !$0.contains("::") }
            )
            if let calls = entry.calls, !frameworkTargetsInTypes.isEmpty {
                entry.calls = calls.filter { !frameworkTargetsInTypes.contains($0) }
            }
        }

        if node.isProtocolRequirement {
            entry.isProtocolRequirement = true
        }

        entries.append(entry)
    }

    return entries
}

func discoverSwiftFiles(in directory: String) -> [String] {
    let fm = FileManager.default
    let skipDirs: Set<String> = [
        ".build", "Build", "DerivedData", "Pods", ".swiftpm",
        "node_modules", ".git", "Carthage", "SourcePackages",
        "checkouts", "artifacts", ".index-build",
    ]
    let skipSuffixes = ["_generated.swift", ".pb.swift", ".grpc.swift"]

    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: directory),
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var files: [String] = []
    while let url = enumerator.nextObject() as? URL {
        let name = url.lastPathComponent
        if skipDirs.contains(name) {
            enumerator.skipDescendants()
            continue
        }
        guard url.pathExtension == "swift" else { continue }
        let shouldSkip = skipSuffixes.contains { name.hasSuffix($0) }
        if shouldSkip {
            emitWarning("Skipping autogenerated file: \(url.path)")
            continue
        }
        files.append(url.path)
    }
    return files.sorted()
}

func runFlagMode(_ args: [String]) throws {
    var workspaceRoot: String?
    var filePaths: [String] = []
    var mode: RunMode = .analyze
    var outputPath: String?
    var scanTargets = false
    var publicOnlyExternal = false
    var summaryOnly = false
    var membersOfId: String?
    var collapseModulesFlag = false

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
        case "--summary-only":
            summaryOnly = true; i += 1
        case "--members-of" where i + 1 < args.count:
            membersOfId = args[i + 1]; i += 2
        case "--collapse-modules":
            collapseModulesFlag = true; i += 1
        case "--full-summary":
            mode = .fullSummary; i += 1
        case "--focus" where i + 1 < args.count:
            mode = .focus(args[i + 1]); i += 2
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
            let targetResolver = TargetResolver(workspaceRoot: root)
            targets = targetResolver.resolve()
            emitProgress(phase: "targets", processed: 1, total: 1)

            if filePaths.isEmpty {
                filePaths = targets.flatMap(\.sourcePaths)
            }

            if publicOnlyExternal {
                for target in targets {
                    if targetResolver.shouldIndexPublicOnly(targetName: target.name, targets: targets) {
                        publicOnlyTargets.insert(target.name)
                    }
                }
            }
        }
    }

    let targetRes: TargetResolver? = workspaceRoot.map { TargetResolver(workspaceRoot: $0) }
    var (allSymbols, fileSources, flagFileImports, _) = scanFiles(filePaths, targets: targets, targetResolver: targetRes)

    if !targets.isEmpty, let targetRes {
        for idx in allSymbols.indices {
            allSymbols[idx].targetName = targetRes.mapFileToTarget(allSymbols[idx].location.file, targets: targets)
        }
    }

    let resources = scanResources(workspaceRoot: workspaceRoot)

    emitProgress(phase: "macros", processed: 0, total: 1)
    var allMacros: [MacroInfo] = []
    let macroTargetResolver = workspaceRoot.map { TargetResolver(workspaceRoot: $0) }
    let macroTargetIndex = targetIndex(targets)
    for (filePath, tree) in fileSources {
        let macroCollector = MacroCollector(filePath: filePath)
        macroCollector.walk(tree)
        var collected = macroCollector.macros
        if !targets.isEmpty {
            let targetName = macroTargetIndex[filePath] ?? macroTargetResolver?.mapFileToTarget(filePath, targets: targets)
            for idx in collected.indices {
                collected[idx].targetName = targetName
            }
        }
        allMacros.append(contentsOf: collected)
    }
    emitProgress(phase: "macros", processed: 1, total: 1)

    emitProgress(phase: "resolving", processed: 0, total: 1)
    let flagProjectRoot = workspaceRoot ?? filePaths.first.map { ($0 as NSString).deletingLastPathComponent } ?? ""
    let flagResolvedURLs = workspaceRoot.map { parsePackageResolved(workspaceRoot: $0) } ?? [:]

    let resolver = DependencyResolver(
        fileSources: fileSources,
        symbols: allSymbols,
        resources: resources,
        targets: targets,
        macros: allMacros,
        publicOnlyTargets: publicOnlyTargets,
        fileImports: flagFileImports,
        projectRoot: flagProjectRoot,
        resolvedURLs: flagResolvedURLs
    )
    let fullResult = resolver.resolve()

    var result: AnalysisResult
    if let membersOfId {
        result = extractMembers(of: membersOfId, from: fullResult)
    } else if summaryOnly {
        result = extractSummary(from: fullResult)
    } else {
        result = fullResult
    }

    if let root = workspaceRoot {
        result = AnalysisResult(
            projectRoot: root,
            nodes: result.nodes,
            links: result.links,
            resources: result.resources,
            targets: result.targets,
            macros: result.macros,
            moduleNodes: result.moduleNodes
        )
    }

    if collapseModulesFlag && !targets.isEmpty {
        result = collapseModules(result: result, targets: targets)
    }

    switch mode {
    case .analyze:
        let json = try safeEncodeToJSON(result, label: "AnalysisResult")
        writeOutput(json, to: outputPath)

    case .context:
        let signaturesByFile = collectSignatures(filePaths: filePaths, fileSources: fileSources)
        let generator = ContextGenerator(analysisResult: result, signaturesByFile: signaturesByFile)
        let context = generator.generate()
        let json = try safeEncodeToJSON(context, label: "PrismContext")
        writeOutput(json, to: outputPath)

    case .findDependents(let targetId):
        let signaturesByFile = collectSignatures(filePaths: filePaths, fileSources: fileSources)
        let generator = ContextGenerator(analysisResult: result, signaturesByFile: signaturesByFile)
        let dependents = generator.generateDependentsOf(targetId)
        let json = try safeEncodeToJSON(dependents, label: "Dependents")
        writeOutput(json, to: outputPath)

    case .fullSummary:
        let summary = generateFullSummary(result: fullResult)
        let json = try safeEncodeToJSON(summary, label: "FullSummary")
        writeOutput(json, to: outputPath)

    case .focus(let rootId):
        let focus = generateFocusAnalysis(rootId: rootId, result: fullResult)
        let json = try safeEncodeToJSON(focus, label: "FocusAnalysis")
        writeOutput(json, to: outputPath)

    case .directScan:
        break
    }

    emitProgress(phase: "complete", processed: 1, total: 1)
}

func generateFocusAnalysis(rootId: String, result: AnalysisResult) -> FocusAnalysis {
    let nodeById = Dictionary(result.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let topLevelFlavors: Set<String> = ["struct", "class", "enum", "actor", "protocol"]

    var outgoing: [String: [String]] = [:]
    for link in result.links {
        outgoing[link.sourceId, default: []].append(link.targetId)
    }

    var required: [String: Int] = [:]
    var queue: [(id: String, depth: Int)] = [(rootId, 0)]
    required[rootId] = 0

    if let rootNode = nodeById[rootId], topLevelFlavors.contains(rootNode.flavor.rawValue) {
        for child in result.nodes where child.parent == rootId {
            if required[child.id] == nil {
                required[child.id] = 1
                queue.append((child.id, 1))
            }
        }
    }

    while !queue.isEmpty {
        let (currentId, depth) = queue.removeFirst()
        let deps = outgoing[currentId] ?? []
        for dep in deps {
            if required[dep] == nil {
                required[dep] = depth + 1
                queue.append((dep, depth + 1))

                if let depNode = nodeById[dep], topLevelFlavors.contains(depNode.flavor.rawValue) {
                    for child in result.nodes where child.parent == dep {
                        if required[child.id] == nil {
                            required[child.id] = depth + 2
                            queue.append((child.id, depth + 2))
                        }
                    }
                }
            }
        }
    }

    let requiredSymbols = required.sorted { $0.value < $1.value }.compactMap { (id, depth) -> FocusSymbol? in
        guard let node = nodeById[id] else { return nil }
        let isStub = depth > 3 && (node.flavor == .function || node.flavor == .initializer)
        return FocusSymbol(
            id: id,
            name: node.name,
            flavor: node.flavor.rawValue,
            depth: depth,
            sourceFile: node.sourceFile,
            isStub: isStub
        )
    }

    let requiredFiles = Array(Set(requiredSymbols.map(\.sourceFile))).sorted()

    let allFiles = Array(Set(result.nodes.map(\.sourceFile))).sorted()
    let redundant = result.nodes.filter { required[$0.id] == nil }.map(\.id).sorted()

    var blastRadius: [String: [String]] = [:]
    for sym in requiredSymbols where sym.depth <= 2 {
        var affected: [String] = []
        for link in result.links where link.targetId == sym.id {
            if required[link.sourceId] != nil {
                affected.append(link.sourceId)
            }
        }
        if !affected.isEmpty {
            blastRadius[sym.id] = affected.sorted()
        }
    }

    let reqCount = requiredSymbols.count
    let totalCount = result.nodes.count
    let reqFiles = requiredFiles.count
    let totalFiles = allFiles.count
    let pct = totalCount > 0 ? Int(Double(reqCount) / Double(totalCount) * 100) : 0

    return FocusAnalysis(
        rootId: rootId,
        requiredSymbols: requiredSymbols,
        requiredFiles: requiredFiles,
        requiredFrameworks: [],
        redundantSymbols: redundant,
        unusedFrameworks: [],
        blastRadius: blastRadius,
        efficiency: FocusEfficiency(
            requiredSymbolCount: reqCount,
            totalSymbolCount: totalCount,
            requiredFileCount: reqFiles,
            totalFileCount: totalFiles,
            requiredFrameworkCount: 0,
            totalFrameworkCount: 0,
            summary: "You need \(pct)% of symbols (\(reqCount)/\(totalCount)) and \(reqFiles)/\(totalFiles) files to build \(rootId)."
        )
    )
}

func generateFullSummary(result: AnalysisResult) -> FullSummary {
    var outgoing: [String: Set<String>] = [:]
    var incoming: [String: Set<String>] = [:]

    for link in result.links {
        outgoing[link.sourceId, default: []].insert(link.targetId)
        incoming[link.targetId, default: []].insert(link.sourceId)
    }

    let allIds = Set(result.nodes.map(\.id))
    let topLevelFlavors: Set<String> = ["struct", "class", "enum", "actor", "protocol"]

    var symbols: [SymbolSummary] = []
    var deadCode: [DeadCodeEntry] = []
    var isolatedTypes = 0
    var writeOnlyCount = 0
    var initOnlyCount = 0

    for node in result.nodes {
        let inRefs = incoming[node.id] ?? []
        let outRefs = outgoing[node.id] ?? []
        let refCount = inRefs.count

        let isVisible = node.isInteresting || topLevelFlavors.contains(node.flavor.rawValue) || node.flavor == .function || node.flavor == .initializer

        symbols.append(SymbolSummary(
            id: node.id,
            name: node.name,
            flavor: node.flavor.rawValue,
            subKind: node.subKind?.rawValue,
            isInteresting: node.isInteresting,
            isVisibleInGraph: isVisible,
            parent: node.parent,
            sourceFile: node.sourceFile,
            line: node.location.line,
            referenceCount: refCount,
            referencedBy: inRefs.sorted(),
            references: outRefs.sorted()
        ))

        if topLevelFlavors.contains(node.flavor.rawValue) && node.parent == nil {
            let hasIncoming = !inRefs.isEmpty
            let hasOutgoing = !outRefs.isEmpty
            if !hasIncoming && !hasOutgoing {
                isolatedTypes += 1
                deadCode.append(DeadCodeEntry(
                    id: node.id,
                    name: node.name,
                    flavor: node.flavor.rawValue,
                    sourceFile: node.sourceFile,
                    line: node.location.line,
                    reason: "Isolated type: no incoming or outgoing dependencies",
                    suggestion: "This type is never referenced by other code. Consider removing it or verifying it's used via runtime/reflection."
                ))
            }
        }

        if node.flavor == .variable && node.subKind?.rawValue == "stored" && !node.isInteresting {
            if refCount == 0 {
                deadCode.append(DeadCodeEntry(
                    id: node.id,
                    name: node.name,
                    flavor: node.flavor.rawValue,
                    sourceFile: node.sourceFile,
                    line: node.location.line,
                    reason: "Stored property never read or written with logic",
                    suggestion: "This property is never referenced outside its declaration. It can be safely removed to reduce memory footprint."
                ))
            }

            let onlyFromInit = inRefs.allSatisfy { ref in
                result.nodes.first { $0.id == ref }?.flavor == .initializer
            }
            if refCount > 0 && onlyFromInit && !inRefs.isEmpty {
                initOnlyCount += 1
                deadCode.append(DeadCodeEntry(
                    id: node.id,
                    name: node.name,
                    flavor: node.flavor.rawValue,
                    sourceFile: node.sourceFile,
                    line: node.location.line,
                    reason: "Property only used during init",
                    suggestion: "This variable is only accessed in initializers and never read again. Consider using a local constant instead."
                ))
            }
        }
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    let deadCount = deadCode.count
    let total = result.nodes.count
    let pct = total > 0 ? Double(deadCount) / Double(total) * 100 : 0

    return FullSummary(
        version: "1.0",
        generatedAt: formatter.string(from: Date()),
        symbols: symbols,
        deadCode: deadCode,
        pruningStats: PruningStats(
            totalSymbols: total,
            deadSymbols: deadCount,
            isolatedTypes: isolatedTypes,
            writeOnlyProperties: writeOnlyCount,
            initOnlyProperties: initOnlyCount,
            estimatedSavings: String(format: "%.1f%% of symbols are candidates for removal", pct)
        )
    )
}

func collapseModules(result: AnalysisResult, targets: [ParsedTarget]) -> AnalysisResult {
    let mainTargetNames = Set(
        targets
            .filter { $0.type == .executable || $0.type == .unknown }
            .map(\.name)
    )
    let macroTargetNames = Set(
        targets
            .filter { $0.type == .macroTarget }
            .map(\.name)
    )
    let collapsibleTargets = Set(
        targets
            .filter { !mainTargetNames.contains($0.name) }
            .map(\.name)
    )

    var symbolsByTarget: [String: [Node]] = [:]
    for node in result.nodes {
        if let t = node.targetName {
            symbolsByTarget[t, default: []].append(node)
        }
    }

    var moduleNodesList: [ModuleNode] = []
    var collapsedIds: Set<String> = []
    var moduleIdForTarget: [String: String] = [:]

    for targetName in collapsibleTargets {
        let symbols = symbolsByTarget[targetName] ?? []
        guard !symbols.isEmpty else { continue }

        let moduleId = "module:\(targetName)"
        moduleIdForTarget[targetName] = moduleId

        let isMacro = macroTargetNames.contains(targetName)
        let publicCount = symbols.filter { $0.access == .public || $0.access == .open }.count
        let targetType = targets.first { $0.name == targetName }?.type ?? .library

        moduleNodesList.append(ModuleNode(
            id: moduleId,
            name: targetName,
            moduleType: targetType,
            isMacro: isMacro,
            symbolCount: symbols.count,
            publicSymbolCount: publicCount
        ))

        for sym in symbols {
            collapsedIds.insert(sym.id)
        }
    }

    let retainedNodes = result.nodes.filter { !collapsedIds.contains($0.id) }

    var retargetedLinks: [Link] = []
    var seenLinks: Set<String> = []

    for link in result.links {
        let sourceTarget = result.nodes.first { $0.id == link.sourceId }?.targetName
        let targetTarget = result.nodes.first { $0.id == link.targetId }?.targetName

        var newSource = link.sourceId
        var newTarget = link.targetId

        if let st = sourceTarget, let moduleId = moduleIdForTarget[st] {
            newSource = moduleId
        }
        if let tt = targetTarget, let moduleId = moduleIdForTarget[tt] {
            newTarget = moduleId
        }

        if newSource == newTarget { continue }

        let key = "\(newSource)->\(newTarget):\(link.type.rawValue)"
        guard seenLinks.insert(key).inserted else { continue }

        retargetedLinks.append(Link(
            sourceId: newSource,
            targetId: newTarget,
            type: link.type,
            confidence: link.confidence,
            references: link.references
        ))
    }

    let moduleAsNodes = moduleNodesList.map { m in
        Node(
            id: m.id,
            name: m.name,
            flavor: m.isMacro ? .macro : .struct,
            subKind: nil,
            isStatic: false,
            isGlobal: false,
            isNested: false,
            isInteresting: true,
            access: .public,
            parent: nil,
            parentFile: nil,
            sourceFile: "",
            location: SourceLocation(file: "", line: 0, column: 0),
            targetName: m.name,
            memberCount: m.symbolCount, parents: nil, implementers: nil, superClass: nil, extensions: nil
        )
    }

    return AnalysisResult(projectRoot: nil, 
        nodes: retainedNodes + moduleAsNodes,
        links: retargetedLinks,
        resources: result.resources,
        targets: result.targets,
        macros: result.macros,
        moduleNodes: moduleNodesList
    )
}

func extractSummary(from result: AnalysisResult) -> AnalysisResult {
    let summaryFlavors: Set<String> = ["struct", "class", "enum", "actor", "protocol"]
    let summaryNodes = result.nodes.filter { summaryFlavors.contains($0.flavor.rawValue) }
    let summaryIds = Set(summaryNodes.map(\.id))

    let memberCounts = result.nodes.reduce(into: [String: Int]()) { counts, node in
        guard let parent = node.parent, !summaryFlavors.contains(node.flavor.rawValue) else { return }
        counts[parent, default: 0] += 1
    }

    let enrichedNodes = summaryNodes.map { node -> Node in
        Node(
            id: node.id,
            name: node.name,
            flavor: node.flavor,
            subKind: node.subKind,
            isStatic: node.isStatic,
            isGlobal: node.isGlobal,
            isNested: node.isNested,
            isInteresting: node.isInteresting,
            access: node.access,
            parent: node.parent,
            parentFile: node.parentFile,
            sourceFile: node.sourceFile,
            location: node.location,
            targetName: node.targetName,
            memberCount: memberCounts[node.id], parents: nil, implementers: nil, superClass: nil, extensions: nil
        )
    }

    let summaryLinks = result.links.filter { summaryIds.contains($0.sourceId) && summaryIds.contains($0.targetId) }

    return AnalysisResult(projectRoot: nil, 
        nodes: enrichedNodes,
        links: summaryLinks,
        resources: result.resources,
        targets: result.targets,
        macros: result.macros,
        moduleNodes: result.moduleNodes
    )
}

func extractMembers(of parentId: String, from result: AnalysisResult) -> AnalysisResult {
    let members = result.nodes.filter { $0.parent == parentId }
    let memberIds = Set(members.map(\.id))
    let relevantIds = memberIds.union([parentId])

    let memberLinks = result.links.filter {
        relevantIds.contains($0.sourceId) && relevantIds.contains($0.targetId)
    }

    let parentNode = result.nodes.filter { $0.id == parentId }

    return AnalysisResult(projectRoot: nil, 
        nodes: parentNode + members,
        links: memberLinks,
        resources: [],
        targets: [],
        macros: [],
        moduleNodes: nil
    )
}

func scanFiles(_ filePaths: [String], targets: [ParsedTarget] = [], targetResolver: TargetResolver? = nil) -> ([SymbolInfo], [(path: String, tree: SourceFileSyntax)], [String: [String]], [String: [SourceLocation]]) {
    let extTargets = Set(targets.filter(\.isExternal).map(\.name))
    let fileToTarget = targetIndex(targets)
    let totalFiles = filePaths.count
    emitProgress(phase: "scanning", processed: 0, total: totalFiles)

    struct ParsedFile {
        var index: Int
        var path: String
        var tree: SourceFileSyntax
        var symbols: [SymbolInfo]
        var imports: [String]
        var extensions: [String: [SourceLocation]]
    }

    let lock = NSLock()
    var parsed: [ParsedFile] = []
    parsed.reserveCapacity(filePaths.count)
    var processed = 0

    DispatchQueue.concurrentPerform(iterations: filePaths.count) { index in
        let path = filePaths[index]
        defer {
            lock.lock()
            processed += 1
            if processed == totalFiles || processed % 64 == 0 {
                emitProgress(phase: "scanning", processed: processed, total: totalFiles)
            }
            lock.unlock()
        }
        if shouldSkipFile(path) { return }
        guard let data = FileManager.default.contents(atPath: path),
              let source = String(data: data, encoding: .utf8) else { return }
        let tree = Parser.parse(source: source)
        let collector = SymbolCollector(filePath: path)
        if targetResolver != nil {
            collector.currentTarget = fileToTarget[path] ?? targetResolver?.mapFileToTarget(path, targets: targets) ?? ""
        }
        collector.externalTargets = extTargets
        collector.walk(tree)
        let item = ParsedFile(
            index: index,
            path: path,
            tree: tree,
            symbols: collector.symbols,
            imports: collector.fileImports,
            extensions: collector.extensionLocations
        )
        lock.lock()
        parsed.append(item)
        lock.unlock()
    }

    parsed.sort { $0.index < $1.index }
    var allSymbols: [SymbolInfo] = []
    var fileSources: [(path: String, tree: SourceFileSyntax)] = []
    var fileImportsMap: [String: [String]] = [:]
    var extensionLocsMap: [String: [SourceLocation]] = [:]
    for item in parsed {
        fileSources.append((path: item.path, tree: item.tree))
        allSymbols.append(contentsOf: item.symbols)
        if !item.imports.isEmpty {
            fileImportsMap[item.path] = item.imports
            fileImportsMap[URL(fileURLWithPath: item.path).lastPathComponent] = item.imports
        }
        for (typeName, locs) in item.extensions {
            extensionLocsMap[typeName, default: []].append(contentsOf: locs)
        }
    }
    return (allSymbols, fileSources, fileImportsMap, extensionLocsMap)
}

private func targetIndex(_ targets: [ParsedTarget]) -> [String: String] {
    var map: [String: String] = [:]
    for target in targets {
        for source in target.sourcePaths {
            map[source] = target.name
        }
    }
    return map
}

func shouldSkipFile(_ path: String) -> Bool {
    let buildIndicators = ["/.build/", "/Build/", "/DerivedData/", "/.swiftpm/", "/checkouts/", "/SourcePackages/", "/.index-build/"]
    for indicator in buildIndicators {
        if path.contains(indicator) { return true }
    }
    let name = (path as NSString).lastPathComponent
    let autoGenSuffixes = ["_generated.swift", ".pb.swift", ".grpc.swift"]
    for suffix in autoGenSuffixes {
        if name.hasSuffix(suffix) { return true }
    }
    return false
}

// ═══════════════════════════════════════════════════════════════════════════════
// Package.resolved parser — extracts Git URLs for SPM dependencies
// Supports v2 (pins[].location) and v3 (pins[].location) formats
// ═══════════════════════════════════════════════════════════════════════════════

func parsePackageResolved(workspaceRoot: String) -> [String: String] {
    let fm = FileManager.default

    // Step 1: Find and parse Package.resolved for identity → URL
    var resolvedFile: String?
    let candidates = [
        (workspaceRoot as NSString).appendingPathComponent("Package.resolved"),
        (workspaceRoot as NSString).appendingPathComponent(".package.resolved"),
    ]
    for c in candidates {
        if fm.fileExists(atPath: c) { resolvedFile = c; break }
    }
    if resolvedFile == nil {
        if let projDir = (try? fm.contentsOfDirectory(atPath: workspaceRoot))?.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let xcResolved = ((workspaceRoot as NSString).appendingPathComponent(projDir) as NSString)
                .appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
            if fm.fileExists(atPath: xcResolved) { resolvedFile = xcResolved }
        }
    }

    var identityToURL: [String: String] = [:]
    if let filePath = resolvedFile,
       let data = fm.contents(atPath: filePath),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let pins = json["pins"] as? [[String: Any]] {
        for pin in pins {
            guard let identity = pin["identity"] as? String,
                  let location = pin["location"] as? String else { continue }
            identityToURL[identity] = location
        }
    }

    // Step 2: Build result with identity, camelCase, and product-name mappings
    var result: [String: String] = [:]
    for (identity, url) in identityToURL {
        result[identity] = url
        let camelCase = identity.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        result[camelCase] = url
    }

    // Step 3: Parse Package.swift for .product(name:, package:) to map product names → package URL
    let manifestPath = (workspaceRoot as NSString).appendingPathComponent("Package.swift")
    if let manifestData = fm.contents(atPath: manifestPath),
       let manifestSource = String(data: manifestData, encoding: .utf8) {
        // Regex: .product(name: "SwiftParser", package: "swift-syntax")
        let pattern = #"\.product\(\s*name:\s*"([^"]+)"\s*,\s*package:\s*"([^"]+)"\s*\)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(manifestSource.startIndex..., in: manifestSource)
            for match in regex.matches(in: manifestSource, range: range) {
                if let nameRange = Range(match.range(at: 1), in: manifestSource),
                   let pkgRange = Range(match.range(at: 2), in: manifestSource) {
                    let productName = String(manifestSource[nameRange])
                    let packageId = String(manifestSource[pkgRange])
                    if let url = identityToURL[packageId] {
                        result[productName] = url
                    }
                }
            }
        }
    }

    return result
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

func safeEncodeToJSON<T: Encodable>(_ value: T, label: String) throws -> String {
    emitProgress(phase: "encoding", processed: 0, total: 1)
    let encoder = JSONEncoder()
    do {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PrismError.encodingFailed(detail: "\(label): encoded data is not valid UTF-8 (\(data.count) bytes)")
        }
        return json
    } catch let error as PrismError {
        throw error
    } catch {
        throw PrismError.encodingFailed(detail: "\(label): \(error)")
    }
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
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    fputs("{\"_warning\":\"\(escaped)\"}\n", stderr)
}

do {
    try run()
} catch let error as PrismError {
    let escaped = error.description
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    fputs("{\"_error\":\"\(escaped)\"}\n", stderr)
    exit(1)
} catch {
    let desc = String(describing: error)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    fputs("{\"_error\":\"Unhandled error: \(desc)\"}\n", stderr)
    exit(1)
}
