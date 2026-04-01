import SwiftSyntax

final class CallCollector: SyntaxVisitor {

    private(set) var calls: [CallRef] = []
    let knownSymbols: Set<String>

    init(knownSymbols: Set<String>) {
        self.knownSymbols = knownSymbols
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let method = memberAccess.declName.baseName.text
            let qualifier = memberAccess.base?.trimmedDescription
            calls.append(CallRef(callee: method, isQualified: true, qualifier: qualifier))
        } else if let identExpr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = identExpr.baseName.text
            calls.append(CallRef(callee: name, isQualified: false, qualifier: nil))
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.as(FunctionCallExprSyntax.self) != nil {
            return .visitChildren
        }
        let member = node.declName.baseName.text
        let qualifier = node.base?.trimmedDescription
        calls.append(CallRef(callee: member, isQualified: true, qualifier: qualifier))
        return .visitChildren
    }
}
