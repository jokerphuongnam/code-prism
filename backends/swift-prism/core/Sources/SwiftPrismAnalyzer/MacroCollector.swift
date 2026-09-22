import SwiftSyntax

struct MacroInfo {
    let id: String
    let name: String
    let macroType: MacroType
    let role: MacroRole?
    let conformances: [String]
    let location: SourceLocation
    var targetName: String?
}

final class MacroCollector: SyntaxVisitor {

    private(set) var macros: [MacroInfo] = []
    private(set) var macroApplications: [(symbolId: String, macroName: String, location: SourceLocation)] = []
    private var containerStack: [String] = []
    private let filePath: String

    init(filePath: String) {
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let id = makeID(parent: containerStack.last, name: name)
        let loc = sourceLocation(of: node)

        macros.append(MacroInfo(
            id: id,
            name: name,
            macroType: .freestanding,
            role: nil,
            conformances: [],
            location: loc,
            targetName: nil
        ))

        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        checkForMacroConformance(name: name, attributes: node.attributes, inheritance: node.inheritanceClause, node: node)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        checkForMacroConformance(name: name, attributes: node.attributes, inheritance: node.inheritanceClause, node: node)
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        containerStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { containerStack.removeLast() }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let attrName = node.attributeName.trimmedDescription

        guard !isBuiltinAttribute(attrName) else { return .visitChildren }

        if let parentDecl = findParentDeclName(node) {
            let loc = sourceLocation(of: node)
            macroApplications.append((
                symbolId: makeID(parent: containerStack.last, name: parentDecl),
                macroName: attrName,
                location: loc
            ))
        }

        return .visitChildren
    }

    private func checkForMacroConformance(name: String, attributes: AttributeListSyntax, inheritance: InheritanceClauseSyntax?, node: some SyntaxProtocol) {
        let conformances = inheritance?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        let macroProtocols = Set(["ExpressionMacro", "DeclarationMacro", "AccessorMacro", "MemberMacro",
                                   "PeerMacro", "MemberAttributeMacro", "ConformanceMacro", "ExtensionMacro",
                                   "CodeItemMacro", "BodyMacro", "PreambleMacro"])

        let matchedConformances = conformances.filter { macroProtocols.contains($0) }
        guard !matchedConformances.isEmpty else { return }

        let id = makeID(parent: containerStack.last, name: name)
        let loc = sourceLocation(of: node)
        let role = inferRole(from: matchedConformances)

        macros.append(MacroInfo(
            id: id,
            name: name,
            macroType: .attached,
            role: role,
            conformances: matchedConformances,
            location: loc,
            targetName: nil
        ))
    }

    private func inferRole(from conformances: [String]) -> MacroRole? {
        let mapping: [String: MacroRole] = [
            "PeerMacro": .peer,
            "MemberMacro": .member,
            "AccessorMacro": .accessor,
            "MemberAttributeMacro": .memberAttribute,
            "ConformanceMacro": .conformance,
            "ExpressionMacro": .expression,
            "DeclarationMacro": .declaration,
            "CodeItemMacro": .codeItem,
            "ExtensionMacro": .extension,
            "BodyMacro": .body,
            "PreambleMacro": .preamble,
        ]
        for c in conformances {
            if let role = mapping[c] { return role }
        }
        return nil
    }

    private func findParentDeclName(_ attr: AttributeSyntax) -> String? {
        var current: Syntax? = Syntax(attr)
        while let parent = current?.parent {
            if let funcDecl = parent.as(FunctionDeclSyntax.self) {
                return funcDecl.name.text
            }
            if let structDecl = parent.as(StructDeclSyntax.self) {
                return structDecl.name.text
            }
            if let classDecl = parent.as(ClassDeclSyntax.self) {
                return classDecl.name.text
            }
            if let enumDecl = parent.as(EnumDeclSyntax.self) {
                return enumDecl.name.text
            }
            if let varDecl = parent.as(VariableDeclSyntax.self) {
                for binding in varDecl.bindings {
                    if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                        return pattern.identifier.text
                    }
                }
            }
            if parent.as(CodeBlockItemListSyntax.self) != nil { break }
            current = parent
        }
        return nil
    }

    private func isBuiltinAttribute(_ name: String) -> Bool {
        let builtins: Set<String> = [
            "available", "objc", "objcMembers", "nonobjc", "discardableResult",
            "frozen", "inlinable", "usableFromInline", "MainActor", "Sendable",
            "preconcurrency", "retroactive", "unchecked", "dynamicMemberLookup",
            "dynamicCallable", "propertyWrapper", "resultBuilder", "globalActor",
            "testable", "escaping", "autoclosure", "convention", "warn_unqualified_access",
            "IBAction", "IBOutlet", "IBDesignable", "IBInspectable", "NSManaged",
            "NSCopying", "UIApplicationMain", "NSApplicationMain", "main",
            "inline", "State", "Binding", "Published", "ObservedObject",
            "StateObject", "EnvironmentObject", "Environment", "AppStorage",
            "SceneStorage", "FetchRequest", "Query", "ViewBuilder",
        ]
        return builtins.contains(name)
    }

    private func makeID(parent: String?, name: String) -> String {
        if let parent { return "\(parent).\(name)" }
        return name
    }

    private func sourceLocation(of node: some SyntaxProtocol) -> SourceLocation {
        let converter = SourceLocationConverter(fileName: filePath, tree: node.root)
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceLocation(file: filePath, line: loc.line, column: loc.column)
    }
}
