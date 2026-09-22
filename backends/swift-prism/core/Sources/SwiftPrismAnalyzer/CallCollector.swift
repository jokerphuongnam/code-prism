import SwiftSyntax

final class CallCollector: SyntaxVisitor {

    private(set) var calls: [CallRef] = []
    let knownSymbols: Set<String>
    private let filePath: String

    init(knownSymbols: Set<String>, filePath: String = "") {
        self.knownSymbols = knownSymbols
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let sig = extractCallSignature(from: node.arguments)
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let method = memberAccess.declName.baseName.text
            let qualifier = memberAccess.base?.trimmedDescription
            let loc = sourceLocation(of: node)
            let snippet = node.trimmedDescription.prefix(80)
            calls.append(CallRef(callee: method, isQualified: true, qualifier: qualifier, callSignature: sig, line: loc.line, column: loc.column, snippet: String(snippet), file: filePath))
        } else if let identExpr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = identExpr.baseName.text
            let loc = sourceLocation(of: node)
            let snippet = node.trimmedDescription.prefix(80)
            calls.append(CallRef(callee: name, isQualified: false, qualifier: nil, callSignature: sig, line: loc.line, column: loc.column, snippet: String(snippet), file: filePath))
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.as(FunctionCallExprSyntax.self) != nil {
            return .visitChildren
        }
        let member = node.declName.baseName.text
        let qualifier = node.base?.trimmedDescription
        let loc = sourceLocation(of: node)
        let snippet = node.trimmedDescription.prefix(80)
        calls.append(CallRef(callee: member, isQualified: true, qualifier: qualifier, callSignature: nil, line: loc.line, column: loc.column, snippet: String(snippet), file: filePath))
        return .visitChildren
    }

    private func extractCallSignature(from args: LabeledExprListSyntax) -> String? {
        if args.isEmpty { return "()" }
        let labels = args.map { arg -> String in
            if let label = arg.label?.text {
                return "\(label):"
            }
            return "_:"
        }
        return "(\(labels.joined()))"
    }

    private func sourceLocation(of node: some SyntaxProtocol) -> SourceLocation {
        let converter = SourceLocationConverter(fileName: filePath, tree: node.root)
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceLocation(file: filePath, line: loc.line, column: loc.column)
    }
}
