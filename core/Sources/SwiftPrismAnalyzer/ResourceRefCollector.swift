import SwiftSyntax

final class ResourceRefCollector: SyntaxVisitor {

    private(set) var refs: [ResourceRef] = []
    private let filePath: String
    private let knownResourceNames: Set<String>

    private static let imageInitNames: Set<String> = ["Image", "UIImage", "NSImage"]
    private static let colorInitNames: Set<String> = ["Color", "UIColor", "NSColor"]
    private static let bundleMethodNames: Set<String> = ["url", "path", "data"]
    private static let knownWrapperMethods: Set<String> = [
        "getColor", "getImage", "color", "image", "asset", "resource",
        "loadImage", "loadColor", "namedColor", "namedImage",
    ]

    init(filePath: String, knownResourceNames: Set<String> = []) {
        self.filePath = filePath
        self.knownResourceNames = knownResourceNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let identExpr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let callee = identExpr.baseName.text
            if Self.imageInitNames.contains(callee) || Self.colorInitNames.contains(callee) {
                extractFirstStringArg(from: node, context: callee, confidence: .high)
            }
        }

        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let method = memberAccess.declName.baseName.text

            if let base = memberAccess.base {
                let baseText = base.trimmedDescription

                if Self.imageInitNames.contains(baseText) || Self.colorInitNames.contains(baseText) {
                    if method == "init" {
                        extractFirstStringArg(from: node, context: baseText, confidence: .high)
                        extractNamedArg(from: node, label: "named", context: baseText, confidence: .high)
                    }
                    if method == "named" {
                        extractFirstStringArg(from: node, context: baseText, confidence: .high)
                    }
                }

                if Self.bundleMethodNames.contains(method) {
                    extractBundleResourceRef(from: node, method: method)
                }

                if Self.knownWrapperMethods.contains(method) {
                    extractFirstStringArg(from: node, context: "\(baseText).\(method)", confidence: .medium)
                }
            }

            if Self.knownWrapperMethods.contains(method) && memberAccess.base == nil {
                extractFirstStringArg(from: node, context: method, confidence: .medium)
            }
        }

        scanForHeuristicMatches(in: node)

        return .visitChildren
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard !knownResourceNames.isEmpty else { return .visitChildren }

        guard let literal = extractPlainString(from: node) else { return .visitChildren }
        guard knownResourceNames.contains(literal) else { return .visitChildren }

        if isInsideKnownResourceCall(node) { return .visitChildren }

        let loc = sourceLocation(of: node)
        refs.append(ResourceRef(
            resourceName: literal,
            callContext: "heuristic_literal",
            confidence: .high,
            location: loc
        ))

        return .visitChildren
    }

    private func scanForHeuristicMatches(in call: FunctionCallExprSyntax) {
        guard !knownResourceNames.isEmpty else { return }

        let callee = call.calledExpression.trimmedDescription
        let isKnownCall = Self.imageInitNames.contains(callee)
            || Self.colorInitNames.contains(callee)
            || Self.knownWrapperMethods.contains(callee.components(separatedBy: ".").last ?? "")

        if isKnownCall { return }

        for arg in call.arguments {
            guard let literal = extractStringLiteral(from: arg.expression) else { continue }
            guard knownResourceNames.contains(literal) else { continue }
            let loc = sourceLocation(of: arg)
            refs.append(ResourceRef(
                resourceName: literal,
                callContext: "heuristic:\(callee)",
                confidence: .high,
                location: loc
            ))
        }
    }

    private func isInsideKnownResourceCall(_ node: StringLiteralExprSyntax) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if parent.as(FunctionCallExprSyntax.self) != nil { return true }
            if parent.as(CodeBlockItemSyntax.self) != nil { break }
            current = parent
        }
        return false
    }

    private func extractFirstStringArg(from call: FunctionCallExprSyntax, context: String, confidence: LinkConfidence) {
        for arg in call.arguments {
            if let stringLiteral = extractStringLiteral(from: arg.expression) {
                let loc = sourceLocation(of: arg)
                refs.append(ResourceRef(resourceName: stringLiteral, callContext: context, confidence: confidence, location: loc))
                return
            }
        }
    }

    private func extractNamedArg(from call: FunctionCallExprSyntax, label: String, context: String, confidence: LinkConfidence) {
        for arg in call.arguments {
            guard arg.label?.text == label else { continue }
            if let stringLiteral = extractStringLiteral(from: arg.expression) {
                let loc = sourceLocation(of: arg)
                refs.append(ResourceRef(resourceName: stringLiteral, callContext: context, confidence: confidence, location: loc))
                return
            }
        }
    }

    private func extractBundleResourceRef(from call: FunctionCallExprSyntax, method: String) {
        for arg in call.arguments {
            let label = arg.label?.text ?? ""
            guard label == "forResource" || label == "forAuxiliaryExecutable" else { continue }
            if let stringLiteral = extractStringLiteral(from: arg.expression) {
                let loc = sourceLocation(of: arg)
                refs.append(ResourceRef(resourceName: stringLiteral, callContext: "Bundle.\(method)", confidence: .high, location: loc))
                return
            }
        }
    }

    private func extractStringLiteral(from expr: ExprSyntax) -> String? {
        extractPlainString(from: expr)
    }

    private func extractPlainString(from node: some SyntaxProtocol) -> String? {
        guard let stringLiteral = node.as(StringLiteralExprSyntax.self) else { return nil }
        guard stringLiteral.segments.count == 1,
              let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return segment.content.text
    }

    private func sourceLocation(of node: some SyntaxProtocol) -> SourceLocation {
        let converter = SourceLocationConverter(fileName: filePath, tree: node.root)
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceLocation(file: filePath, line: loc.line, column: loc.column)
    }
}
