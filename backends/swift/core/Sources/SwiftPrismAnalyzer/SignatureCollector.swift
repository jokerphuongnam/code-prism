import SwiftSyntax

struct SignatureInfo {
    let id: String
    let signature: String
    let flavor: SymbolFlavor
    let access: AccessLevel
    let parent: String?
    let file: String
    let line: Int
}

final class SignatureCollector: SyntaxVisitor {

    private(set) var signatures: [SignatureInfo] = []
    private var containerStack: [String] = []
    private let filePath: String

    init(filePath: String) {
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else {
            containerStack.append(name)
            return .visitChildren
        }
        let inheritance = node.inheritanceClause.map { ": \($0.inheritedTypes.map { $0.type.trimmedDescription }.joined(separator: ", "))" } ?? ""
        let sig = "\(access.rawValue) class \(name)\(inheritance)"
        let line = lineNumber(of: node)
        signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: name), signature: sig, flavor: .class, access: access, parent: containerStack.last, file: filePath, line: line))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else {
            containerStack.append(name)
            return .visitChildren
        }
        let inheritance = node.inheritanceClause.map { ": \($0.inheritedTypes.map { $0.type.trimmedDescription }.joined(separator: ", "))" } ?? ""
        let sig = "\(access.rawValue) struct \(name)\(inheritance)"
        let line = lineNumber(of: node)
        signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: name), signature: sig, flavor: .struct, access: access, parent: containerStack.last, file: filePath, line: line))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else {
            containerStack.append(name)
            return .visitChildren
        }
        let sig = "\(access.rawValue) enum \(name)"
        let line = lineNumber(of: node)
        signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: name), signature: sig, flavor: .enum, access: access, parent: containerStack.last, file: filePath, line: line))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else {
            containerStack.append(name)
            return .visitChildren
        }
        let sig = "\(access.rawValue) protocol \(name)"
        let line = lineNumber(of: node)
        signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: name), signature: sig, flavor: .protocol, access: access, parent: containerStack.last, file: filePath, line: line))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else {
            containerStack.append(name)
            return .visitChildren
        }
        let sig = "\(access.rawValue) actor \(name)"
        let line = lineNumber(of: node)
        signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: name), signature: sig, flavor: .actor, access: access, parent: containerStack.last, file: filePath, line: line))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else { return .skipChildren }
        let name = node.name.text
        let params = node.signature.parameterClause.parameters.map { p in
            let label = p.firstName.text
            let type = p.type.trimmedDescription
            return "\(label): \(type)"
        }.joined(separator: ", ")
        let ret = node.signature.returnClause.map { " -> \($0.type.trimmedDescription)" } ?? ""
        let staticMod = hasStaticModifier(node.modifiers) ? "static " : ""
        let sig = "\(access.rawValue) \(staticMod)func \(name)(\(params))\(ret)"
        let line = lineNumber(of: node)
        signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: name), signature: sig, flavor: .function, access: access, parent: containerStack.last, file: filePath, line: line))
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else { return .skipChildren }
        let staticMod = hasStaticModifier(node.modifiers) ? "static " : ""
        let keyword = node.bindingSpecifier.text

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text
            let typeAnnotation = binding.typeAnnotation.map { ": \($0.type.trimmedDescription)" } ?? ""
            let sig = "\(access.rawValue) \(staticMod)\(keyword) \(name)\(typeAnnotation)"
            let line = lineNumber(of: binding)
            signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: name), signature: sig, flavor: .variable, access: access, parent: containerStack.last, file: filePath, line: line))
        }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let access = accessLevel(from: node.modifiers)
        guard shouldInclude(access) else { return .skipChildren }
        let params = node.signature.parameterClause.parameters.map { p in
            let label = p.firstName.text
            let type = p.type.trimmedDescription
            return "\(label): \(type)"
        }.joined(separator: ", ")
        let sig = "\(access.rawValue) init(\(params))"
        let line = lineNumber(of: node)
        signatures.append(SignatureInfo(id: makeID(parent: containerStack.last, name: "init"), signature: sig, flavor: .initializer, access: access, parent: containerStack.last, file: filePath, line: line))
        return .skipChildren
    }

    private func shouldInclude(_ access: AccessLevel) -> Bool {
        access != .private && access != .fileprivate
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

    private func lineNumber(of node: some SyntaxProtocol) -> Int {
        let converter = SourceLocationConverter(fileName: filePath, tree: node.root)
        return converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
}
