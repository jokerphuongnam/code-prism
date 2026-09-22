import SwiftSyntax

struct InheritanceRef {
    let declId: String
    let inheritedName: String
    let linkType: LinkType
}

final class InheritanceCollector: SyntaxVisitor {

    private(set) var refs: [InheritanceRef] = []
    private var containerStack: [String] = []
    private let knownTypeNames: Set<String>

    init(knownTypeNames: Set<String>) {
        self.knownTypeNames = knownTypeNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        collectInheritance(name: name, clause: node.inheritanceClause, isClass: true)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        collectInheritance(name: name, clause: node.inheritanceClause, isClass: false)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        collectInheritance(name: name, clause: node.inheritanceClause, isClass: false)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        collectInheritance(name: name, clause: node.inheritanceClause, isClass: false)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        collectInheritance(name: name, clause: node.inheritanceClause, isClass: false)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.trimmedDescription
        collectInheritance(name: name, clause: node.inheritanceClause, isClass: false)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { containerStack.removeLast() }

    private func collectInheritance(name: String, clause: InheritanceClauseSyntax?, isClass: Bool) {
        guard let clause else { return }
        for (index, inherited) in clause.inheritedTypes.enumerated() {
            let typeName = inherited.type.trimmedDescription
            guard knownTypeNames.contains(typeName) else { continue }
            let linkType: LinkType = (isClass && index == 0) ? .inheritance : .conformance
            refs.append(InheritanceRef(declId: name, inheritedName: typeName, linkType: linkType))
        }
    }
}
