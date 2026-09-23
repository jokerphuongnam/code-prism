import SwiftSyntax

struct EnumUsageRef {
    let callSiteId: String
    let memberName: String
    let location: SourceLocation
}

final class EnumUsageCollector: SyntaxVisitor {

    private(set) var usages: [EnumUsageRef] = []
    private var containerStack: [String] = []
    private let filePath: String

    init(filePath: String) {
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

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

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.extendedType.trimmedDescription); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.base == nil else { return .visitChildren }

        let memberName = node.declName.baseName.text
        let callSite = containerStack.last ?? ""
        guard !callSite.isEmpty else { return .visitChildren }

        let loc = sourceLocation(of: node)
        usages.append(EnumUsageRef(callSiteId: callSite, memberName: memberName, location: loc))

        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil {
            let memberName = memberAccess.declName.baseName.text
            let callSite = containerStack.last ?? ""
            if !callSite.isEmpty {
                let loc = sourceLocation(of: node)
                usages.append(EnumUsageRef(callSiteId: callSite, memberName: memberName, location: loc))
            }
        }
        return .visitChildren
    }

    private func sourceLocation(of node: some SyntaxProtocol) -> SourceLocation {
        let converter = SourceLocationConverter(fileName: filePath, tree: node.root)
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceLocation(file: filePath, line: loc.line, column: loc.column)
    }
}
