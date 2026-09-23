import Foundation
import SwiftSyntax

struct DependencyResolver {

    let fileSources: [(path: String, tree: SourceFileSyntax)]
    let symbols: [SymbolInfo]
    let resources: [ResourceNode]
    let targets: [ParsedTarget]
    let macros: [MacroInfo]
    let publicOnlyTargets: Set<String>
    let fileImports: [String: [String]]
    let projectRoot: String
    let resolvedURLs: [String: String]

    private static let resourceProviderProtocols: Set<String> = [
        "ResourceProvider", "AssetProvider", "ImageProvider", "ColorProvider",
        "ThemeProvider", "DesignTokenProvider",
    ]

    func resolve() -> AnalysisResult {
        let knownNames = Set(symbols.map(\.name))
        let nameToID = buildNameToIDMap()
        let qualifiedMap = buildQualifiedNameMap()
        let typeNames = Set(symbols.filter { [.struct, .class, .enum, .actor, .protocol].contains($0.flavor) }.map(\.name))
        let resourceNameToID = buildResourceNameToIDMap()
        let resourceNames = Set(resources.map(\.name))
        let resourceProviderTypes = collectResourceProviderConformers()
        let symbolTargetMap = buildSymbolTargetMap()
        let macroNameSet = Set(macros.map(\.name))

        let externalTargetNames = Set(targets.filter(\.isExternal).map(\.name))

        var links: [Link] = []
        var seen: Set<String> = []
        let obsMap = buildObserverMap()
        let symbolsByFile = Dictionary(grouping: symbols, by: \.location.file)
        var envValuesByName: [String: [SymbolInfo]] = [:]
        for sym in symbols where sym.parent == "EnvironmentValues" {
            envValuesByName[sym.name, default: []].append(sym)
        }
        var symbolById: [String: SymbolInfo] = [:]
        symbolById.reserveCapacity(symbols.count)
        for sym in symbols where symbolById[sym.id] == nil {
            symbolById[sym.id] = sym
        }
        var enumCaseToType: [String: String] = [:]
        for sym in symbols where sym.flavor == .variable && sym.parent != nil {
            if let parentSym = symbolById[sym.parent!], parentSym.flavor == .enum {
                enumCaseToType[sym.name] = parentSym.id
            }
        }

        let fileCount = fileSources.count
        let lock = NSLock()
        var fileBatches: [(Int, [Link])] = []
        fileBatches.reserveCapacity(fileCount)
        DispatchQueue.concurrentPerform(iterations: fileCount) { index in
            let (filePath, tree) = fileSources[index]
            let batch = self.linksForFile(
                filePath: filePath,
                tree: tree,
                localSymbols: symbolsByFile[filePath] ?? [],
                knownNames: knownNames,
                nameToID: nameToID,
                qualifiedMap: qualifiedMap,
                typeNames: typeNames,
                resourceNameToID: resourceNameToID,
                resourceNames: resourceNames,
                resourceProviderTypes: resourceProviderTypes,
                symbolTargetMap: symbolTargetMap,
                macroNameSet: macroNameSet,
                externalTargetNames: externalTargetNames,
                obsMap: obsMap,
                envValuesByName: envValuesByName,
                enumCaseToType: enumCaseToType
            )
            lock.lock()
            fileBatches.append((index, batch))
            lock.unlock()
        }
        for batch in fileBatches.sorted(by: { $0.0 < $1.0 }) {
            for link in batch.1 {
                let key = "\(link.sourceId)->\(link.targetId):\(link.type.rawValue)"
                if seen.insert(key).inserted {
                    links.append(link)
                }
            }
        }


        for sym in symbols {
            guard sym.flavor == .variable, let parent = sym.parent, let typeName = sym.resolvedType else { continue }
            guard let targetId = nameToID[typeName] ?? typeNames.first(where: { $0 == typeName }) else { continue }
            let key = "\(parent)->\(targetId):holds_type:\(sym.name)"
            if seen.insert(key).inserted {
                links.append(Link(sourceId: parent, targetId: targetId, type: .holdsType, confidence: .high, references: nil))
            }
        }

        var implementersMap: [String: [String]] = [:]
        var superClassMap: [String: String] = [:]
        var extensionFilesMap: [String: Set<String>] = [:]

        for link in links {
            if link.type == .conformance {
                implementersMap[link.targetId, default: []].append(link.sourceId)
            }
            if link.type == .inheritance {
                superClassMap[link.sourceId] = link.targetId
            }
            if link.type == .extensionContribution {
                let typeName = link.targetId
                let fileName = String(link.sourceId.dropFirst("file:".count))
                extensionFilesMap[typeName, default: []].insert(fileName)
            }
        }

        let typeResolver = TypeModuleResolver(symbols: symbols)

        let nodes = symbols
            .filter { sym in
                if publicOnlyTargets.contains(sym.targetName ?? "") {
                    return sym.access == .public || sym.access == .open || sym.access == .package
                }
                return true
            }
            .map { sym -> Node in
                var parents: [String] = []
                if let p = sym.parent { parents.append(p) }
                parents.append("file:\(sym.sourceFile)")

                let extFiles = extensionFilesMap[sym.id]
                if let extFiles {
                    for f in extFiles { parents.append("file:\(f)") }
                }

                let isType = [SymbolFlavor.struct, .class, .enum, .actor, .protocol].contains(sym.flavor)

                return Node(
                    id: sym.id, name: sym.name, flavor: sym.flavor, subKind: sym.subKind,
                    isStatic: sym.isStatic, isGlobal: sym.isGlobal, isNested: sym.isNested,
                    isInteresting: sym.isInteresting, access: sym.access,
                    parent: sym.parent, parentFile: sym.parentFile, sourceFile: sym.sourceFile,
                    location: sym.location, targetName: sym.targetName, memberCount: nil,
                    parents: parents.isEmpty ? nil : parents,
                    implementers: isType ? implementersMap[sym.id] : nil,
                    superClass: superClassMap[sym.id],
                    extensions: isType ? extFiles.map { Array($0).sorted() } : nil,
                    signature: sym.signature,
                    isProtocolRequirement: sym.isProtocolRequirement,
                    returnTypes: typeResolver.resolveModules(for: sym.returnTypes),
                    parameterTypes: typeResolver.resolveModules(for: sym.parameterTypes)
                )
            }

        let targetInfos = targets.map {
            TargetInfo(name: $0.name, type: $0.type, path: $0.path, dependencies: $0.dependencies, isExternal: $0.isExternal, remoteURL: $0.remoteURL)
        }

        let macroNodes = macros.map {
            MacroNode(id: $0.id, name: $0.name, macroType: $0.macroType, role: $0.role, conformances: $0.conformances, generatedSymbols: findGeneratedSymbols(macroName: $0.name, links: links), location: $0.location, targetName: $0.targetName)
        }

        var primaryFileForType: [String: String] = [:]
        for sym in symbols {
            let isTypeDecl = [SymbolFlavor.struct, .class, .enum, .actor, .protocol].contains(sym.flavor)
            if isTypeDecl && sym.parent == nil {
                if primaryFileForType[sym.name] == nil {
                    primaryFileForType[sym.name] = sym.sourceFile
                }
            }
        }

        for sym in symbols {
            guard sym.isNested, let parent = sym.parent else { continue }
            let key = "\(parent)->\(sym.id):nesting"
            if seen.insert(key).inserted {
                links.append(Link(sourceId: parent, targetId: sym.id, type: .nesting, confidence: nil, references: nil))
            }
        }

        var extensionContributions: Set<String> = []
        for sym in symbols {
            guard let parent = sym.parent else { continue }
            guard let primaryFile = primaryFileForType[parent] else { continue }
            if sym.sourceFile != primaryFile {
                let key = "file:\(sym.sourceFile)->type:\(parent)"
                if extensionContributions.insert(key).inserted {
                    links.append(Link(sourceId: "file:\(sym.sourceFile)", targetId: parent, type: .extensionContribution, confidence: nil, references: nil))
                }
            }
        }

        var allNodes = nodes

        var mainAttrTypes: Set<String> = []
        for (_, tree) in fileSources {
            let checker = MainAttrChecker()
            checker.walk(tree)
            mainAttrTypes.formUnion(checker.mainTypes)
        }

        var entryPointsByTarget: [String: [String]] = [:]
        let targetNames = Set(targets.map(\.name))
        let defaultTarget = targets.first?.name ?? "Default"

        for sym in symbols {
            let symTarget = sym.targetName ?? defaultTarget

            if mainAttrTypes.contains(sym.id) && (sym.flavor == .struct || sym.flavor == .class) {
                entryPointsByTarget[symTarget, default: []].append(sym.id)
                for child in symbols where child.parent == sym.id && (child.flavor == .initializer || child.name == "body") {
                    entryPointsByTarget[symTarget, default: []].append(child.id)
                }
            }

            if sym.name == "main" && sym.flavor == .function && sym.parent == nil {
                entryPointsByTarget[symTarget, default: []].append(sym.id)
            }
        }

        if entryPointsByTarget.isEmpty {
            for sym in symbols where sym.name == "run" && sym.flavor == .function && sym.parent == nil {
                let t = sym.targetName ?? defaultTarget
                entryPointsByTarget[t, default: []].append(sym.id)
            }
        }

        for (targetName, entryPoints) in entryPointsByTarget {
            let mainId = "MAIN::\(targetName)"
            let mainNode = Node(
                id: mainId, name: "Main (\(targetName))", flavor: .entryPoint, subKind: nil,
                isStatic: false, isGlobal: true, isNested: false, isInteresting: true,
                access: .public, parent: nil, parentFile: nil, sourceFile: "",
                location: SourceLocation(file: "", line: 0, column: 0),
                targetName: targetName, memberCount: nil,
                parents: ["target:\(targetName)"], implementers: nil, superClass: nil, extensions: nil
            )
            allNodes.append(mainNode)

            for ep in entryPoints {
                let key = "\(mainId)->\(ep):call"
                if seen.insert(key).inserted {
                    links.append(Link(sourceId: mainId, targetId: ep, type: .call, confidence: .high, references: nil))
                }
            }
        }

        for sym in symbols {
            let allTypes = (sym.returnTypes ?? []) + (sym.parameterTypes ?? [])
            for typeName in allTypes {
                if let targetId = nameToID[typeName] ?? typeNames.first(where: { $0 == typeName }) {
                    if targetId == sym.id || targetId == sym.parent { continue }
                    let key = "\(sym.id)->\(targetId):holds_type:\(typeName)"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: sym.id, targetId: targetId, type: .holdsType, confidence: .medium, references: nil))
                    }
                } else {
                    for target in targets where target.isExternal {
                        let targetSymbols = symbols.filter { $0.targetName == target.name }
                        if targetSymbols.contains(where: { $0.name == typeName }) {
                            let key = "\(sym.id)->\(target.name):holds_type:\(typeName)"
                            if seen.insert(key).inserted {
                                links.append(Link(sourceId: sym.id, targetId: target.name, type: .holdsType, confidence: .low, references: nil))
                            }
                            break
                        }
                    }
                }
            }
        }

        // --- Target Nodes (Internal + External + System) ---
        let systemFrameworks: Set<String> = [
            "Swift", "Foundation", "UIKit", "SwiftUI", "CoreFoundation", "CoreGraphics",
            "CoreData", "CoreLocation", "MapKit", "AVFoundation", "Photos", "Contacts",
            "EventKit", "StoreKit", "GameKit", "CloudKit", "WatchKit", "WidgetKit",
            "AppKit", "SceneKit", "SpriteKit", "Metal", "MetalKit", "CoreImage",
            "CoreText", "CoreAnimation", "QuartzCore", "Security", "CryptoKit",
            "os", "Dispatch", "ObjectiveC", "Darwin", "Combine", "Observation",
            "RegexBuilder", "SwiftData", "RealityKit", "ARKit", "CoreML",
            "NaturalLanguage", "Vision", "CoreBluetooth", "CoreMotion",
            "CoreTelephony", "NetworkExtension", "Network", "MultipeerConnectivity",
            "UserNotifications", "BackgroundTasks", "CoreSpotlight", "Intents",
            "IntentsUI", "ActivityKit", "TipKit", "Charts", "WeatherKit",
            "PackageDescription", "XCTest", "Testing", "SwiftCompilerPlugin",
        ]

        var createdTargetIds = Set<String>()

        // 1) Internal targets — no origin (managed by GLOBAL::MAIN)
        //    sourceFile = "" signals "internal, omit origin in flat output"
        for target in targets where !target.isExternal {
            let targetId = target.name
            guard createdTargetIds.insert(targetId).inserted else { continue }
            allNodes.append(Node(
                id: targetId, name: target.name, flavor: .target, subKind: nil,
                isStatic: false, isGlobal: true, isNested: false, isInteresting: true,
                access: .public, parent: nil, parentFile: nil, sourceFile: "",
                location: SourceLocation(file: "", line: 0, column: 0),
                targetName: targetId, memberCount: nil,
                parents: nil, implementers: nil, superClass: nil, extensions: nil
            ))
        }

        // 2) External targets (SPM/CocoaPods)
        //    Remote → Git URL from Package.resolved
        //    Local  → absolute path to the dependency folder
        for target in targets where target.isExternal {
            let targetId = target.name
            guard createdTargetIds.insert(targetId).inserted else { continue }
            let gitURL = target.remoteURL
                ?? resolvedURLs[target.name]
                ?? resolvedURLs[target.name.lowercased()]
            let origin: String
            if let url = gitURL {
                origin = url                          // Remote: Git URL
            } else if target.path.hasPrefix("/") {
                origin = target.path                   // Local: absolute path
            } else {
                origin = projectRoot + "/" + target.path
            }
            allNodes.append(Node(
                id: targetId, name: target.name, flavor: .target, subKind: nil,
                isStatic: false, isGlobal: true, isNested: false, isInteresting: true,
                access: .public, parent: nil, parentFile: nil, sourceFile: origin,
                location: SourceLocation(file: origin, line: 0, column: 0),
                targetName: targetId, memberCount: nil,
                parents: nil, implementers: nil, superClass: nil, extensions: nil
            ))
        }

        // 3) System framework + imported module nodes
        var allImportedModules = Set<String>()
        for (_, imports) in fileImports {
            for imp in imports { allImportedModules.insert(imp) }
        }

        for moduleName in allImportedModules {
            guard moduleName != "Swift" else { continue }
            guard createdTargetIds.insert(moduleName).inserted else { continue }
            let isSystem = systemFrameworks.contains(moduleName)
            let origin: String
            if isSystem {
                origin = "Apple"                       // Apple SDK
            } else if let url = resolvedURLs[moduleName] ?? resolvedURLs[moduleName.lowercased()] {
                origin = url                           // Remote: Git URL
            } else {
                origin = "External"                    // Unknown external
            }
            allNodes.append(Node(
                id: moduleName, name: moduleName, flavor: .target, subKind: nil,
                isStatic: false, isGlobal: true, isNested: false, isInteresting: true,
                access: .public, parent: nil, parentFile: nil, sourceFile: origin,
                location: SourceLocation(file: origin, line: 0, column: 0),
                targetName: moduleName, memberCount: nil,
                parents: nil, implementers: nil, superClass: nil, extensions: nil
            ))
        }

        // Build file→owning-target map
        let fileToTarget: [String: String] = {
            var m: [String: String] = [:]
            for sym in symbols {
                if let t = sym.targetName {
                    m[sym.sourceFile] = t
                    let basename = sym.sourceFile.split(separator: "/").last.map(String.init) ?? sym.sourceFile
                    m[basename] = t
                }
            }
            return m
        }()

        // Link MAIN entry points → owning internal target
        for (targetName, _) in entryPointsByTarget {
            let mainId = "MAIN::\(targetName)"
            if createdTargetIds.contains(targetName) {
                let key = "\(mainId)->\(targetName):import_dependency"
                if seen.insert(key).inserted {
                    links.append(Link(sourceId: mainId, targetId: targetName, type: .importDependency, confidence: .high, references: nil))
                }
            }
        }

        // Link import_dependency: owning target → imported framework
        let internalTargetNames = Set(targets.filter { !$0.isExternal }.map(\.name))
        for (filePath, imports) in fileImports {
            let fileBasename = filePath.split(separator: "/").last.map(String.init) ?? filePath
            guard let ownerTarget = fileToTarget[filePath] ?? fileToTarget[fileBasename] else { continue }
            for moduleName in imports {
                guard moduleName != "Swift" else { continue }
                guard moduleName != ownerTarget else { continue }
                let key = "\(ownerTarget)->\(moduleName):import_dependency"
                if seen.insert(key).inserted {
                    links.append(Link(sourceId: ownerTarget, targetId: moduleName, type: .importDependency, confidence: .high, references: nil))
                }
            }
        }

        // Link symbols whose parameterTypes/returnTypes resolve to external modules
        for node in nodes {
            let resolvedModules = (node.parameterTypes ?? []) + (node.returnTypes ?? [])
            for moduleName in resolvedModules {
                guard createdTargetIds.contains(moduleName), !internalTargetNames.contains(moduleName) else { continue }
                let key = "\(node.id)->\(moduleName):import_dependency:\(moduleName)"
                if seen.insert(key).inserted {
                    links.append(Link(sourceId: node.id, targetId: moduleName, type: .importDependency, confidence: .medium, references: nil))
                }
            }
        }

        return AnalysisResult(projectRoot: nil, nodes: allNodes, links: links, resources: resources, targets: targetInfos, macros: macroNodes, moduleNodes: nil)
    }

    private func findGeneratedSymbols(macroName: String, links: [Link]) -> [String] {
        links
            .filter { $0.type == .macroExpansion && $0.sourceId == macroName }
            .map(\.targetId)
            .sorted()
    }

    private func buildSymbolTargetMap() -> [String: String] {
        var map: [String: String] = [:]
        for sym in symbols {
            if let target = sym.targetName {
                map[sym.id] = target
            }
        }
        return map
    }

    private func collectResourceProviderConformers() -> Set<String> {
        var conformers: Set<String> = []
        for (_, tree) in fileSources {
            let collector = InheritanceCollector(knownTypeNames: Self.resourceProviderProtocols)
            collector.walk(tree)
            for ref in collector.refs {
                if Self.resourceProviderProtocols.contains(ref.inheritedName) {
                    conformers.insert(ref.declId)
                }
            }
        }
        return conformers
    }

    private func buildNameToIDMap() -> [String: String] {
        var map: [String: String] = [:]
        for s in symbols where map[s.name] == nil {
            map[s.name] = s.id
        }
        return map
    }

    private func buildQualifiedNameMap() -> [String: String] {
        var map: [String: String] = [:]
        for s in symbols {
            if let parent = s.parent {
                map["\(parent).\(s.name)"] = s.id
                if let sig = s.signature {
                    map["\(parent).\(s.name)\(sig)"] = s.id
                }
            }
        }
        return map
    }

    private func resolveQualifiedCall(call: CallRef, nameToID: [String: String], qualifiedMap: [String: String], callerParent: String?) -> String? {
        let calleeName = call.callee
        let calleeSigned = call.callSignature.map { "\(calleeName)\($0)" } ?? calleeName

        if call.isQualified, let qualifier = call.qualifier {
            for key in ["\(qualifier).\(calleeSigned)", "\(qualifier).\(calleeName)"] {
                if let id = qualifiedMap[key] { return id }
            }

            let qualifierType = symbols.first { $0.name == qualifier && $0.parent == callerParent }?.resolvedType
                ?? symbols.first { $0.name == qualifier }?.resolvedType

            if let typeName = qualifierType {
                for key in ["\(typeName).\(calleeSigned)", "\(typeName).\(calleeName)"] {
                    if let id = qualifiedMap[key] { return id }
                }

                for s in symbols where s.name == typeName && s.flavor == .variable {
                    if let deepType = s.resolvedType {
                        for key in ["\(deepType).\(calleeSigned)", "\(deepType).\(calleeName)"] {
                            if let id = qualifiedMap[key] { return id }
                        }
                    }
                }
            }
        }

        if let id = nameToID[calleeSigned] { return id }
        return nameToID[calleeName]
    }

    private func buildResourceNameToIDMap() -> [String: String] {
        var map: [String: String] = [:]
        for r in resources where map[r.name] == nil {
            map[r.name] = r.id
        }
        return map
    }

    private func resolveToExternalTarget(call: CallRef, callerParent: String?) -> String? {
        guard call.isQualified, let qualifier = call.qualifier else { return nil }

        let qualifierSym = symbols.first { $0.name == qualifier && $0.parent == callerParent }
            ?? symbols.first { $0.name == qualifier }

        if let sym = qualifierSym, let resolvedType = sym.resolvedType {
            if let target = targets.first(where: { $0.isExternal && $0.name == resolvedType }) {
                return target.name
            }
            for target in targets where target.isExternal {
                let targetSymbols = symbols.filter { $0.targetName == target.name }
                if targetSymbols.contains(where: { $0.name == resolvedType }) {
                    return target.name
                }
            }
        }

        for target in targets where target.isExternal {
            if target.name == qualifier {
                return target.name
            }
        }

        return nil
    }

    private func buildObserverMap() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for sym in symbols where sym.subKind == .willSet || sym.subKind == .didSet {
            let varName = sym.name.components(separatedBy: ".").first ?? sym.name
            let varID = sym.parent.map { "\($0).\(varName)" } ?? varName
            map[varID, default: []].append(sym.id)
        }
        return map
    }

    private func determineLinkType(call: CallRef, targetID: String) -> LinkType {
        let targetSymbol = symbols.first { $0.id == targetID }
        if let target = targetSymbol, target.flavor == .variable { return .access }
        return .call
    }

    private func resolveAccessTarget(targetID: String, observerMap: [String: [String]]) -> [(id: String, type: LinkType)] {
        if let observers = observerMap[targetID], !observers.isEmpty {
            return observers.map { (id: $0, type: .observerTrigger) }
        }
        return [(id: targetID, type: .access)]
    }

    private func collectObserverTriggerLinks(symbol: SymbolInfo, bodyNode: Syntax, nameToID: [String: String], seen: inout Set<String>, links: inout [Link]) {
        guard symbol.subKind == .willSet || symbol.subKind == .didSet else { return }
        let varName = symbol.name.components(separatedBy: ".").first ?? symbol.name
        let varID = symbol.parent.map { "\($0).\(varName)" } ?? varName

        let key = "\(varID)->\(symbol.id):observer_trigger"
        if seen.insert(key).inserted {
            links.append(Link(sourceId: varID, targetId: symbol.id, type: .observerTrigger, confidence: nil, references: nil))
        }
    }

    private func linksForFile(
        filePath: String,
        tree: SourceFileSyntax,
        localSymbols: [SymbolInfo],
        knownNames: Set<String>,
        nameToID: [String: String],
        qualifiedMap: [String: String],
        typeNames: Set<String>,
        resourceNameToID: [String: String],
        resourceNames: Set<String>,
        resourceProviderTypes: Set<String>,
        symbolTargetMap: [String: String],
        macroNameSet: Set<String>,
        externalTargetNames: Set<String>,
        obsMap: [String: [String]],
        envValuesByName: [String: [SymbolInfo]],
        enumCaseToType: [String: String]
    ) -> [Link] {
        var links: [Link] = []
        var seen: Set<String> = []
        let bodyFinder = BodyFinder()
        bodyFinder.walk(tree)

        for symbol in localSymbols {
            if publicOnlyTargets.contains(symbol.targetName ?? "") && symbol.access == .private || symbol.access == .fileprivate {
                continue
            }
            guard let bodyNode = bodyFinder.bodies[symbol.id] else { continue }
            let collector = CallCollector(knownSymbols: knownNames, filePath: filePath)
            collector.walk(bodyNode)
            var refsByTarget: [String: [CallSiteRef]] = [:]
            for call in collector.calls {
                let ref = CallSiteRef(line: call.line, column: call.column, snippet: call.snippet, file: call.file)
                if let targetID = resolveQualifiedCall(call: call, nameToID: nameToID, qualifiedMap: qualifiedMap, callerParent: symbol.parent), targetID != symbol.id {
                    let resolvedTarget = symbolTargetMap[targetID]
                    let isExternalSymbol = resolvedTarget.flatMap { externalTargetNames.contains($0) } ?? false
                    if isExternalSymbol, let t = resolvedTarget {
                        refsByTarget[t, default: []].append(ref)
                    } else {
                        refsByTarget[targetID, default: []].append(ref)
                    }
                } else if let externalTarget = resolveToExternalTarget(call: call, callerParent: symbol.parent) {
                    refsByTarget[externalTarget, default: []].append(ref)
                }
            }
            for (targetID, refs) in refsByTarget {
                let sourceTarget = symbolTargetMap[symbol.id]
                let destTarget = symbolTargetMap[targetID]
                let isCrossTarget = sourceTarget != nil && destTarget != nil && sourceTarget != destTarget
                if isCrossTarget {
                    let key = "\(symbol.id)->\(targetID):cross_target_dependency"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: symbol.id, targetId: targetID, type: .crossTargetDependency, confidence: nil, references: refs))
                    }
                } else {
                    let baseType = determineLinkType(call: CallRef(callee: "", isQualified: false, qualifier: nil, callSignature: nil, line: 0, column: 0, snippet: "", file: ""), targetID: targetID)
                    if baseType == .access {
                        for resolved in resolveAccessTarget(targetID: targetID, observerMap: obsMap) {
                            let key = "\(symbol.id)->\(resolved.id):\(resolved.type.rawValue)"
                            if seen.insert(key).inserted {
                                links.append(Link(sourceId: symbol.id, targetId: resolved.id, type: resolved.type, confidence: nil, references: refs))
                            }
                        }
                    } else {
                        let key = "\(symbol.id)->\(targetID):\(baseType.rawValue)"
                        if seen.insert(key).inserted {
                            links.append(Link(sourceId: symbol.id, targetId: targetID, type: baseType, confidence: nil, references: refs))
                        }
                    }
                }
            }
            collectObserverTriggerLinks(symbol: symbol, bodyNode: bodyNode, nameToID: nameToID, seen: &seen, links: &links)
        }

        for symbol in localSymbols {
            guard let bodyNode = bodyFinder.bodies[symbol.id] else { continue }
            let refCollector = ResourceRefCollector(filePath: filePath, knownResourceNames: resourceNames)
            refCollector.walk(bodyNode)
            for ref in refCollector.refs {
                guard let targetID = resourceNameToID[ref.resourceName] else { continue }
                let linkType: LinkType = ref.callContext.hasPrefix("heuristic") ? .heuristicLink : .resourceLink
                let key = "\(symbol.id)->\(targetID):\(linkType.rawValue)"
                if seen.insert(key).inserted {
                    links.append(Link(sourceId: symbol.id, targetId: targetID, type: linkType, confidence: ref.confidence, references: nil))
                }
            }
        }

        let staticCollector = StaticResourcePropertyCollector()
        staticCollector.walk(tree)
        for alias in staticCollector.aliases {
            guard let targetID = resourceNameToID[alias.resourceName] else { continue }
            let key = "\(alias.symbolId)->\(targetID):resource_alias"
            if seen.insert(key).inserted {
                links.append(Link(sourceId: alias.symbolId, targetId: targetID, type: .resourceAlias, confidence: .high, references: nil))
            }
        }

        for providerType in resourceProviderTypes {
            for member in localSymbols where member.parent == providerType {
                guard let bodyNode = bodyFinder.bodies[member.id] else { continue }
                let refCollector = ResourceRefCollector(filePath: filePath, knownResourceNames: resourceNames)
                refCollector.walk(bodyNode)
                for ref in refCollector.refs {
                    guard let targetID = resourceNameToID[ref.resourceName] else { continue }
                    let key = "\(member.id)->\(targetID):resource_link:provider"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: member.id, targetId: targetID, type: .resourceLink, confidence: .high, references: nil))
                    }
                }
            }
        }

        let macroCollector = MacroCollector(filePath: filePath)
        macroCollector.walk(tree)
        for app in macroCollector.macroApplications where macroNameSet.contains(app.macroName) {
            let key = "\(app.symbolId)->\(app.macroName):macro_expansion"
            if seen.insert(key).inserted {
                links.append(Link(sourceId: app.macroName, targetId: app.symbolId, type: .macroExpansion, confidence: .high, references: nil))
            }
        }

        let inheritanceCollector = InheritanceCollector(knownTypeNames: typeNames)
        inheritanceCollector.walk(tree)
        for ref in inheritanceCollector.refs {
            let key = "\(ref.declId)->\(ref.inheritedName):\(ref.linkType.rawValue)"
            if seen.insert(key).inserted {
                links.append(Link(sourceId: ref.declId, targetId: ref.inheritedName, type: ref.linkType, confidence: nil, references: nil))
            }
        }

        let envCollector = EnvironmentCollector(filePath: filePath)
        envCollector.walk(tree)
        for ref in envCollector.refs {
            switch ref.kind {
            case .environmentObject, .environment:
                if let targetId = nameToID[ref.typeName] ?? typeNames.first(where: { $0 == ref.typeName }) {
                    let key = "\(ref.consumerId)->\(targetId):environment_injection"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: ref.consumerId, targetId: targetId, type: .environmentInjection, confidence: .medium, references: nil))
                    }
                }
                if let keyPath = ref.keyPath {
                    let envKeyName = keyPath.replacingOccurrences(of: "\\.", with: "").replacingOccurrences(of: "\\", with: "")
                    for sym in envValuesByName[envKeyName] ?? [] {
                        let key = "\(ref.consumerId)->\(sym.id):environment_injection"
                        if seen.insert(key).inserted {
                            links.append(Link(sourceId: ref.consumerId, targetId: sym.id, type: .environmentInjection, confidence: .high, references: nil))
                        }
                    }
                }
            case .providesObject:
                if let targetId = nameToID[ref.typeName] ?? typeNames.first(where: { $0 == ref.typeName }) {
                    let key = "\(ref.consumerId)->\(targetId):environment_provider"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: ref.consumerId, targetId: targetId, type: .environmentProvider, confidence: .medium, references: nil))
                    }
                }
            case .providesValue:
                if let keyPath = ref.keyPath {
                    let envKeyName = keyPath.replacingOccurrences(of: "\\.", with: "").replacingOccurrences(of: "\\", with: "")
                    for sym in envValuesByName[envKeyName] ?? [] {
                        let key = "\(ref.consumerId)->\(sym.id):environment_provider"
                        if seen.insert(key).inserted {
                            links.append(Link(sourceId: ref.consumerId, targetId: sym.id, type: .environmentProvider, confidence: .high, references: nil))
                        }
                    }
                }
            }
        }

        let enumCollector = EnumUsageCollector(filePath: filePath)
        enumCollector.walk(tree)
        for usage in enumCollector.usages {
            if let enumId = enumCaseToType[usage.memberName] {
                let key = "\(usage.callSiteId)->\(enumId):enum_usage:\(usage.memberName)"
                if seen.insert(key).inserted {
                    links.append(Link(sourceId: usage.callSiteId, targetId: enumId, type: .enumUsage, confidence: .medium, references: nil))
                }
            }
        }
        return links
    }
}

private final class BodyFinder: SyntaxVisitor {

    var bodies: [String: Syntax] = [:]
    private var containerStack: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.extendedType.trimmedDescription); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            let sig = extractSig(from: node.signature.parameterClause)
            bodies[makeID(name: node.name.text, signature: sig)] = Syntax(body)
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let id = makeID(name: pattern.identifier.text)
            if let accessorBlock = binding.accessorBlock {
                bodies[id] = Syntax(accessorBlock)
            }
            if let initializer = binding.initializer {
                bodies[id] = Syntax(initializer)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            let sig = extractSig(from: node.signature.parameterClause)
            bodies[makeID(name: "init", signature: sig)] = Syntax(body)
        }
        return .visitChildren
    }

    private func makeID(name: String, signature: String? = nil) -> String {
        let fullName = signature.map { "\(name)\($0)" } ?? name
        if let parent = containerStack.last { return "\(parent).\(fullName)" }
        return fullName
    }

    private func extractSig(from clause: FunctionParameterClauseSyntax) -> String? {
        let params = clause.parameters
        if params.isEmpty { return "()" }
        let labels = params.map { p -> String in
            let label = p.firstName.text
            return label == "_" ? "_:" : "\(label):"
        }
        return "(\(labels.joined()))"
    }

}

private final class MainAttrChecker: SyntaxVisitor {
    var mainTypes: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasMainAttr(node.attributes) { mainTypes.insert(node.name.text) }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasMainAttr(node.attributes) { mainTypes.insert(node.name.text) }
        return .skipChildren
    }

    private func hasMainAttr(_ attrs: AttributeListSyntax) -> Bool {
        attrs.contains { attr in
            guard let a = attr.as(AttributeSyntax.self) else { return false }
            let name = a.attributeName.trimmedDescription
            return name == "main" || name == "UIApplicationMain" || name == "NSApplicationMain"
        }
    }
}
