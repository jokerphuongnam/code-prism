import SwiftSyntax

struct DependencyResolver {

    let fileSources: [(path: String, tree: SourceFileSyntax)]
    let symbols: [SymbolInfo]
    let resources: [ResourceNode]
    let targets: [ParsedTarget]
    let macros: [MacroInfo]
    let publicOnlyTargets: Set<String>

    private static let resourceProviderProtocols: Set<String> = [
        "ResourceProvider", "AssetProvider", "ImageProvider", "ColorProvider",
        "ThemeProvider", "DesignTokenProvider",
    ]

    func resolve() -> AnalysisResult {
        let knownNames = Set(symbols.map(\.name))
        let nameToID = buildNameToIDMap()
        let typeNames = Set(symbols.filter { [.struct, .class, .enum, .actor, .protocol].contains($0.flavor) }.map(\.name))
        let resourceNameToID = buildResourceNameToIDMap()
        let resourceNames = Set(resources.map(\.name))
        let resourceProviderTypes = collectResourceProviderConformers()
        let symbolTargetMap = buildSymbolTargetMap()
        let macroNameSet = Set(macros.map(\.name))

        var links: [Link] = []
        var seen: Set<String> = []

        for (filePath, tree) in fileSources {
            let bodyFinder = BodyFinder()
            bodyFinder.walk(tree)

            for symbol in symbols {
                if publicOnlyTargets.contains(symbol.targetName ?? "") && symbol.access == .private || symbol.access == .fileprivate {
                    continue
                }

                guard let bodyNode = bodyFinder.bodies[symbol.id] else { continue }
                let collector = CallCollector(knownSymbols: knownNames, filePath: filePath)
                collector.walk(bodyNode)

                var refsByTarget: [String: [CallSiteRef]] = [:]

                for call in collector.calls {
                    guard let targetID = nameToID[call.callee], targetID != symbol.id else { continue }
                    refsByTarget[targetID, default: []].append(CallSiteRef(
                        line: call.line,
                        column: call.column,
                        snippet: call.snippet,
                        file: call.file
                    ))
                }

                for (targetID, refs) in refsByTarget {
                    let sourceTarget = symbolTargetMap[symbol.id]
                    let destTarget = symbolTargetMap[targetID]
                    let isCrossTarget = sourceTarget != nil && destTarget != nil && sourceTarget != destTarget
                    let linkType: LinkType = isCrossTarget ? .crossTargetDependency : determineLinkType(call: CallRef(callee: "", isQualified: false, qualifier: nil, line: 0, column: 0, snippet: "", file: ""), targetID: targetID)
                    let key = "\(symbol.id)->\(targetID):\(linkType.rawValue)"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: symbol.id, targetId: targetID, type: linkType, confidence: nil, references: refs))
                    }
                }

                collectObserverTriggerLinks(symbol: symbol, bodyNode: bodyNode, nameToID: nameToID, seen: &seen, links: &links)
            }

            for symbol in symbols.filter({ $0.location.file == filePath }) {
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
                let membersOfProvider = symbols.filter { $0.parent == providerType }
                for member in membersOfProvider {
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
            for app in macroCollector.macroApplications {
                if macroNameSet.contains(app.macroName) {
                    let key = "\(app.symbolId)->\(app.macroName):macro_expansion"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: app.macroName, targetId: app.symbolId, type: .macroExpansion, confidence: .high, references: nil))
                    }
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
                        for sym in symbols where sym.name == envKeyName && sym.parent == "EnvironmentValues" {
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
                        for sym in symbols where sym.name == envKeyName && sym.parent == "EnvironmentValues" {
                            let key = "\(ref.consumerId)->\(sym.id):environment_provider"
                            if seen.insert(key).inserted {
                                links.append(Link(sourceId: ref.consumerId, targetId: sym.id, type: .environmentProvider, confidence: .high, references: nil))
                            }
                        }
                    }
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

        var enumCaseToType: [String: String] = [:]
        for sym in symbols where sym.flavor == .variable && sym.parent != nil {
            let parentSym = symbols.first { $0.id == sym.parent && $0.flavor == .enum }
            if let parentSym {
                enumCaseToType[sym.name] = parentSym.id
            }
        }

        let staticMethodReturnTypes: [String: String] = [:]

        for (filePath, tree) in fileSources {
            let enumCollector = EnumUsageCollector(filePath: filePath)
            enumCollector.walk(tree)

            for usage in enumCollector.usages {
                if let enumId = enumCaseToType[usage.memberName] {
                    let key = "\(usage.callSiteId)->\(enumId):enum_usage:\(usage.memberName)"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: usage.callSiteId, targetId: enumId, type: .enumUsage, confidence: .medium, references: nil))
                    }
                }

                if let returnType = staticMethodReturnTypes[usage.memberName],
                   let targetId = nameToID[returnType] ?? typeNames.first(where: { $0 == returnType }) {
                    let key = "\(usage.callSiteId)->\(targetId):call:\(usage.memberName)"
                    if seen.insert(key).inserted {
                        links.append(Link(sourceId: usage.callSiteId, targetId: targetId, type: .call, confidence: .medium, references: nil))
                    }
                }
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
                    extensions: isType ? extFiles.map { Array($0).sorted() } : nil
                )
            }

        let targetInfos = targets.map {
            TargetInfo(name: $0.name, type: $0.type, path: $0.path, dependencies: $0.dependencies)
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

    private func buildResourceNameToIDMap() -> [String: String] {
        var map: [String: String] = [:]
        for r in resources where map[r.name] == nil {
            map[r.name] = r.id
        }
        return map
    }

    private func determineLinkType(call: CallRef, targetID: String) -> LinkType {
        let targetSymbol = symbols.first { $0.id == targetID }
        if let target = targetSymbol, target.flavor == .variable { return .access }
        return .call
    }

    private func collectObserverTriggerLinks(symbol: SymbolInfo, bodyNode: Syntax, nameToID: [String: String], seen: inout Set<String>, links: inout [Link]) {
        guard symbol.subKind == .willSet || symbol.subKind == .didSet else { return }
        let varName = symbol.name.components(separatedBy: ".").first ?? symbol.name
        let varID: String
        if let parent = symbol.parent {
            varID = "\(parent).\(varName)"
        } else {
            varID = varName
        }

        let key = "\(varID)->\(symbol.id):observer_trigger"
        if seen.insert(key).inserted {
            links.append(Link(sourceId: varID, targetId: symbol.id, type: .observerTrigger, confidence: nil, references: nil))
        }
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
            bodies[makeID(name: node.name.text)] = Syntax(body)
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
            bodies[makeID(name: "init")] = Syntax(body)
        }
        return .visitChildren
    }

    private func makeID(name: String) -> String {
        if let parent = containerStack.last { return "\(parent).\(name)" }
        return name
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
