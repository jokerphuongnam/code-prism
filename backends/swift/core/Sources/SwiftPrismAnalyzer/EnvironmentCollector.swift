import SwiftSyntax

struct EnvironmentRef {
    let consumerId: String
    let typeName: String
    let keyPath: String?
    let kind: EnvironmentRefKind
    let location: SourceLocation
}

enum EnvironmentRefKind {
    case environmentObject
    case environment
    case providesObject
    case providesValue
}

final class EnvironmentCollector: SyntaxVisitor {

    private(set) var refs: [EnvironmentRef] = []
    private var containerStack: [String] = []
    private let filePath: String

    private static let wrapperAttrs: Set<String> = ["EnvironmentObject", "Environment", "AppStorage", "SceneStorage"]
    private static let providerMethods: Set<String> = ["environmentObject", "environment"]

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

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let parent = containerStack.last else { return .visitChildren }

        for attr in node.attributes {
            guard let attribute = attr.as(AttributeSyntax.self) else { continue }
            let attrName = attribute.attributeName.trimmedDescription

            if attrName == "EnvironmentObject" {
                if let typeName = extractTypeAnnotation(from: node) {
                    let loc = sourceLocation(of: node)
                    refs.append(EnvironmentRef(consumerId: parent, typeName: typeName, keyPath: nil, kind: .environmentObject, location: loc))
                }
            }

            if attrName == "Environment" {
                let keyPath = extractKeyPathArg(from: attribute)
                let typeName = extractTypeAnnotation(from: node) ?? keyPath ?? "Unknown"
                let loc = sourceLocation(of: node)
                refs.append(EnvironmentRef(consumerId: parent, typeName: typeName, keyPath: keyPath, kind: .environment, location: loc))
            }

            if attrName == "AppStorage" || attrName == "SceneStorage" {
                if let typeName = extractTypeAnnotation(from: node) {
                    let loc = sourceLocation(of: node)
                    refs.append(EnvironmentRef(consumerId: parent, typeName: attrName, keyPath: nil, kind: .environment, location: loc))
                }
            }
        }

        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }

        let method = memberAccess.declName.baseName.text
        guard Self.providerMethods.contains(method) else { return .visitChildren }

        let provider = containerStack.last ?? "Unknown"
        let loc = sourceLocation(of: node)

        if method == "environmentObject" {
            if let firstArg = node.arguments.first {
                let argType = firstArg.expression.trimmedDescription
                refs.append(EnvironmentRef(consumerId: provider, typeName: argType, keyPath: nil, kind: .providesObject, location: loc))
            }
        }

        if method == "environment" {
            if let firstArg = node.arguments.first {
                let keyPath = firstArg.expression.trimmedDescription
                let typeName: String
                if node.arguments.count >= 2 {
                    typeName = Array(node.arguments)[1].expression.trimmedDescription
                } else {
                    typeName = keyPath
                }
                refs.append(EnvironmentRef(consumerId: provider, typeName: typeName, keyPath: keyPath, kind: .providesValue, location: loc))
            }
        }

        return .visitChildren
    }

    private func extractTypeAnnotation(from varDecl: VariableDeclSyntax) -> String? {
        for binding in varDecl.bindings {
            if let typeAnnotation = binding.typeAnnotation {
                return typeAnnotation.type.trimmedDescription
            }
        }
        return nil
    }

    private func extractKeyPathArg(from attr: AttributeSyntax) -> String? {
        guard let args = attr.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for arg in args {
            let text = arg.expression.trimmedDescription
            if text.hasPrefix("\\.") || text.hasPrefix("\\") {
                return text
            }
        }
        return nil
    }

    private func sourceLocation(of node: some SyntaxProtocol) -> SourceLocation {
        let converter = SourceLocationConverter(fileName: filePath, tree: node.root)
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceLocation(file: filePath, line: loc.line, column: loc.column)
    }
}
