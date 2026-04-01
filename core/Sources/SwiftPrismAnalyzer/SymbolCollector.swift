import SwiftSyntax

final class SymbolCollector: SyntaxVisitor {

    private(set) var symbols: [SymbolInfo] = []
    private var containerStack: [String] = []
    private let filePath: String

    init(filePath: String) {
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        symbols.append(SymbolInfo(id: id, name: name, flavor: .class, subKind: nil, isStatic: false, access: access, parent: parent, location: loc))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        symbols.append(SymbolInfo(id: id, name: name, flavor: .struct, subKind: nil, isStatic: false, access: access, parent: parent, location: loc))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        symbols.append(SymbolInfo(id: id, name: name, flavor: .enum, subKind: nil, isStatic: false, access: access, parent: parent, location: loc))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        symbols.append(SymbolInfo(id: id, name: name, flavor: .actor, subKind: nil, isStatic: false, access: access, parent: parent, location: loc))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        symbols.append(SymbolInfo(id: id, name: name, flavor: .protocol, subKind: nil, isStatic: false, access: access, parent: parent, location: loc))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let loc = sourceLocation(of: node)
        let name = node.name.text
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let id = makeID(parent: parent, name: name)
        let isStatic = hasStaticModifier(node.modifiers)
        symbols.append(SymbolInfo(id: id, name: name, flavor: .function, subKind: nil, isStatic: isStatic, access: access, parent: parent, location: loc))
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let isStatic = hasStaticModifier(node.modifiers)

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text
            let id = makeID(parent: parent, name: name)
            let loc = sourceLocation(of: binding)

            let subKind = resolveVarSubKind(binding)
            symbols.append(SymbolInfo(id: id, name: name, flavor: .variable, subKind: subKind, isStatic: isStatic, access: access, parent: parent, location: loc))

            collectObserverSymbols(binding: binding, varName: name, parent: parent, access: access, isStatic: isStatic)
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let id = makeID(parent: parent, name: "init")
        symbols.append(SymbolInfo(id: id, name: "init", flavor: .initializer, subKind: nil, isStatic: false, access: access, parent: parent, location: loc))
        return .visitChildren
    }

    private func collectObserverSymbols(binding: PatternBindingSyntax, varName: String, parent: String?, access: AccessLevel, isStatic: Bool) {
        guard let accessorBlock = binding.accessorBlock,
              case .accessors(let accessors) = accessorBlock.accessors else { return }

        for accessor in accessors {
            let kind = accessor.accessorSpecifier.text
            guard kind == "willSet" || kind == "didSet" else { continue }
            let subKind: SymbolSubKind = kind == "willSet" ? .willSet : .didSet
            let name = "\(varName).\(kind)"
            let id = makeID(parent: parent, name: name)
            let loc = sourceLocation(of: accessor)
            symbols.append(SymbolInfo(id: id, name: name, flavor: .variable, subKind: subKind, isStatic: isStatic, access: access, parent: parent, location: loc))
        }
    }

    private func resolveVarSubKind(_ binding: PatternBindingSyntax) -> SymbolSubKind? {
        guard let accessorBlock = binding.accessorBlock else {
            return binding.initializer != nil ? .stored : .stored
        }
        switch accessorBlock.accessors {
        case .accessors(let list):
            let kinds = Set(list.map { $0.accessorSpecifier.text })
            if kinds.contains("willSet") || kinds.contains("didSet") { return .stored }
            return .computed
        case .getter:
            return .computed
        }
    }

    private func makeID(parent: String?, name: String) -> String {
        if let parent { return "\(parent).\(name)" }
        return name
    }

    private func accessLevel(from modifiers: DeclModifierListSyntax) -> AccessLevel {
        let mapping: [String: AccessLevel] = [
            "public": .public, "private": .private, "fileprivate": .fileprivate,
            "internal": .internal, "open": .open, "package": .package
        ]
        for modifier in modifiers {
            if let level = mapping[modifier.name.text] { return level }
        }
        return .internal
    }

    private func hasStaticModifier(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
    }

    private func sourceLocation(of node: some SyntaxProtocol) -> SourceLocation {
        let converter = SourceLocationConverter(fileName: filePath, tree: node.root)
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceLocation(file: filePath, line: loc.line, column: loc.column)
    }
}
