import SwiftSyntax

final class StaticResourcePropertyCollector: SyntaxVisitor {

    private(set) var aliases: [StaticResourceAlias] = []
    private var containerStack: [String] = []

    private static let imageTypes: Set<String> = ["Image", "UIImage", "NSImage"]
    private static let colorTypes: Set<String> = ["Color", "UIColor", "NSColor"]

    init() {
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

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        guard isStatic else { return .visitChildren }

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let propertyName = pattern.identifier.text
            let symbolId = makeID(name: propertyName)

            if let initializer = binding.initializer {
                if let resourceName = extractResourceFromExpression(initializer.value) {
                    aliases.append(StaticResourceAlias(
                        symbolId: symbolId,
                        resourceName: resourceName.name,
                        resourceKind: resourceName.kind
                    ))
                }
            }

            if let accessorBlock = binding.accessorBlock {
                if let resourceName = extractResourceFromAccessorBlock(accessorBlock) {
                    aliases.append(StaticResourceAlias(
                        symbolId: symbolId,
                        resourceName: resourceName.name,
                        resourceKind: resourceName.kind
                    ))
                }
            }
        }

        return .visitChildren
    }

    private func extractResourceFromExpression(_ expr: ExprSyntax) -> (name: String, kind: StaticResourceKind)? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }

        if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let callee = ident.baseName.text
            if Self.imageTypes.contains(callee) {
                return extractFirstStringArg(from: call).map { ($0, .image) }
            }
            if Self.colorTypes.contains(callee) {
                return extractFirstStringArg(from: call).map { ($0, .color) }
            }
        }

        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let method = memberAccess.declName.baseName.text
            if let base = memberAccess.base?.trimmedDescription {
                if Self.imageTypes.contains(base) && (method == "init" || method == "named") {
                    let name = extractFirstStringArg(from: call) ?? extractNamedArg(from: call, label: "named")
                    return name.map { ($0, .image) }
                }
                if Self.colorTypes.contains(base) && (method == "init" || method == "named") {
                    let name = extractFirstStringArg(from: call) ?? extractNamedArg(from: call, label: "named")
                    return name.map { ($0, .color) }
                }
            }
        }

        return nil
    }

    private func extractResourceFromAccessorBlock(_ block: AccessorBlockSyntax) -> (name: String, kind: StaticResourceKind)? {
        switch block.accessors {
        case .getter(let body):
            return extractResourceFromCodeBlockItems(body)
        case .accessors(let list):
            for accessor in list {
                guard accessor.accessorSpecifier.text == "get" else { continue }
                if let body = accessor.body {
                    return extractResourceFromCodeBlockItems(body.statements)
                }
            }
        }
        return nil
    }

    private func extractResourceFromCodeBlockItems(_ items: CodeBlockItemListSyntax) -> (name: String, kind: StaticResourceKind)? {
        for item in items {
            if let returnStmt = item.item.as(ReturnStmtSyntax.self),
               let expr = returnStmt.expression {
                return extractResourceFromExpression(expr)
            }
            if let expr = item.item.as(ExprSyntax.self) {
                return extractResourceFromExpression(expr)
            }
        }
        return nil
    }

    private func extractFirstStringArg(from call: FunctionCallExprSyntax) -> String? {
        for arg in call.arguments {
            if let s = extractStringLiteral(from: arg.expression) { return s }
        }
        return nil
    }

    private func extractNamedArg(from call: FunctionCallExprSyntax, label: String) -> String? {
        for arg in call.arguments {
            guard arg.label?.text == label else { continue }
            return extractStringLiteral(from: arg.expression)
        }
        return nil
    }

    private func extractStringLiteral(from expr: ExprSyntax) -> String? {
        guard let stringLiteral = expr.as(StringLiteralExprSyntax.self) else { return nil }
        guard stringLiteral.segments.count == 1,
              let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return segment.content.text
    }

    private func makeID(name: String) -> String {
        if let parent = containerStack.last { return "\(parent).\(name)" }
        return name
    }
}
