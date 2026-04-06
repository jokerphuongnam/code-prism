import Foundation
import SwiftSyntax

final class SymbolCollector: SyntaxVisitor {

    private(set) var symbols: [SymbolInfo] = []
    private(set) var fileImports: [String] = []
    /// Maps extended type name → [(file, line, col)] for extension block locations
    private(set) var extensionLocations: [String: [SourceLocation]] = [:]
    private var containerStack: [String] = []
    private let filePath: String
    private let fileName: String
    private var insideExtension = false
    private var insideProtocol = false
    private var functionBodyDepth = 0
    var currentTarget: String = ""
    var externalTargets: Set<String> = []

    init(filePath: String) {
        self.filePath = filePath
        self.fileName = URL(fileURLWithPath: filePath).lastPathComponent
        super.init(viewMode: .sourceAccurate)
    }

    private var insideFunctionBody: Bool { functionBodyDepth > 0 }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let moduleName = node.path.map { $0.name.text }.joined(separator: ".")
        if !moduleName.isEmpty {
            fileImports.append(moduleName)
        }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        let global = containerStack.isEmpty && !insideExtension
        let nested = !containerStack.isEmpty && !insideExtension
        symbols.append(SymbolInfo(id: id, name: name, flavor: .class, subKind: nil, isStatic: false, isGlobal: global, isNested: nested, isInteresting: true, resolvedType: nil, parentFile: global ? fileName : nil, sourceFile: fileName, access: access, parent: parent, location: loc, signature: nil, isProtocolRequirement: false, returnTypes: nil, parameterTypes: nil))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) {
        if !insideFunctionBody { containerStack.removeLast() }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        let global = containerStack.isEmpty && !insideExtension
        let nested = !containerStack.isEmpty && !insideExtension
        symbols.append(SymbolInfo(id: id, name: name, flavor: .struct, subKind: nil, isStatic: false, isGlobal: global, isNested: nested, isInteresting: true, resolvedType: nil, parentFile: global ? fileName : nil, sourceFile: fileName, access: access, parent: parent, location: loc, signature: nil, isProtocolRequirement: false, returnTypes: nil, parameterTypes: nil))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) {
        if !insideFunctionBody { containerStack.removeLast() }
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        let global = containerStack.isEmpty && !insideExtension
        let nested = !containerStack.isEmpty && !insideExtension
        symbols.append(SymbolInfo(id: id, name: name, flavor: .enum, subKind: nil, isStatic: false, isGlobal: global, isNested: nested, isInteresting: true, resolvedType: nil, parentFile: global ? fileName : nil, sourceFile: fileName, access: access, parent: parent, location: loc, signature: nil, isProtocolRequirement: false, returnTypes: nil, parameterTypes: nil))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) {
        if !insideFunctionBody { containerStack.removeLast() }
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        let global = containerStack.isEmpty && !insideExtension
        let nested = !containerStack.isEmpty && !insideExtension
        symbols.append(SymbolInfo(id: id, name: name, flavor: .actor, subKind: nil, isStatic: false, isGlobal: global, isNested: nested, isInteresting: true, resolvedType: nil, parentFile: global ? fileName : nil, sourceFile: fileName, access: access, parent: parent, location: loc, signature: nil, isProtocolRequirement: false, returnTypes: nil, parameterTypes: nil))
        containerStack.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) {
        if !insideFunctionBody { containerStack.removeLast() }
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let name = node.name.text
        let id = makeID(parent: parent, name: name)
        let global = containerStack.isEmpty && !insideExtension
        let nested = !containerStack.isEmpty && !insideExtension
        symbols.append(SymbolInfo(id: id, name: name, flavor: .protocol, subKind: nil, isStatic: false, isGlobal: global, isNested: nested, isInteresting: true, resolvedType: nil, parentFile: global ? fileName : nil, sourceFile: fileName, access: access, parent: parent, location: loc, signature: nil, isProtocolRequirement: false, returnTypes: nil, parameterTypes: nil))
        containerStack.append(name)
        insideProtocol = true
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) {
        if !insideFunctionBody { containerStack.removeLast() }
        insideProtocol = false
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.extendedType.trimmedDescription
        containerStack.append(typeName)
        insideExtension = true
        let loc = sourceLocation(of: Syntax(node))
        extensionLocations[typeName, default: []].append(loc)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        containerStack.removeLast()
        if containerStack.isEmpty { insideExtension = false }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let loc = sourceLocation(of: node)
        let name = node.name.text
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let isStatic = hasStaticModifier(node.modifiers)
        let global = containerStack.isEmpty && !insideExtension
        let sig = extractSignature(from: node.signature.parameterClause)
        let id = makeID(parent: parent, name: name, signature: sig)

        var params: [String] = []
        for param in node.signature.parameterClause.parameters {
            params.append(contentsOf: extractAllTypes(from: param.type))
        }

        var returns: [String] = []
        if let returnClause = node.signature.returnClause {
            returns = extractAllTypes(from: returnClause.type)
        }

        symbols.append(SymbolInfo(
            id: id, name: name, flavor: .function, subKind: nil,
            isStatic: isStatic, isGlobal: global, isNested: false, isInteresting: true,
            resolvedType: nil, parentFile: global ? fileName : nil, sourceFile: fileName,
            access: access, parent: parent, location: loc, signature: sig,
            isProtocolRequirement: insideProtocol && !insideExtension,
            returnTypes: returns.isEmpty ? nil : Array(Set(returns)),
            parameterTypes: params.isEmpty ? nil : Array(Set(params))
        ))
        return .visitChildren
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        functionBodyDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) {
        functionBodyDepth -= 1
    }

    private static let interestingWrappers: Set<String> = [
        "Published", "State", "Binding", "ObservedObject", "StateObject",
        "EnvironmentObject", "Environment", "AppStorage", "SceneStorage",
        "FetchRequest", "Query", "Namespace",
    ]

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let isStatic = hasStaticModifier(node.modifiers)
        let global = containerStack.isEmpty && !insideExtension
        let hasWrapper = node.attributes.contains { attr in
            guard let a = attr.as(AttributeSyntax.self) else { return false }
            return Self.interestingWrappers.contains(a.attributeName.trimmedDescription)
        }

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text
            let id = makeID(parent: parent, name: name)
            let loc = sourceLocation(of: binding)

            let subKind = resolveVarSubKind(binding)
            let interesting = subKind == .computed || subKind == .willSet || subKind == .didSet || hasWrapper || isStatic
            let resolvedType = extractResolvedType(binding: binding, node: node)
            let isProtoReq = insideProtocol && !insideExtension
            symbols.append(SymbolInfo(id: id, name: name, flavor: .variable, subKind: subKind, isStatic: isStatic, isGlobal: global, isNested: false, isInteresting: interesting, resolvedType: resolvedType, parentFile: global ? fileName : nil, sourceFile: fileName, access: access, parent: parent, location: loc, signature: nil, isProtocolRequirement: isProtoReq, returnTypes: nil, parameterTypes: nil))

            collectObserverSymbols(binding: binding, varName: name, parent: parent, access: access, isStatic: isStatic, isGlobal: global)
        }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if insideFunctionBody { return .skipChildren }
        let loc = sourceLocation(of: node)
        let access = accessLevel(from: node.modifiers)
        let parent = containerStack.last
        let global = containerStack.isEmpty && !insideExtension
        let sig = extractSignature(from: node.signature.parameterClause)
        let id = makeID(parent: parent, name: "init", signature: sig)

        var params: [String] = []
        for param in node.signature.parameterClause.parameters {
            params.append(contentsOf: extractAllTypes(from: param.type))
        }

        symbols.append(SymbolInfo(
            id: id, name: "init", flavor: .initializer, subKind: nil,
            isStatic: false, isGlobal: global, isNested: false, isInteresting: true,
            resolvedType: nil, parentFile: global ? fileName : nil, sourceFile: fileName,
            access: access, parent: parent, location: loc, signature: sig,
            isProtocolRequirement: insideProtocol && !insideExtension,
            returnTypes: nil,
            parameterTypes: params.isEmpty ? nil : Array(Set(params))
        ))
        return .visitChildren
    }

    private func collectObserverSymbols(binding: PatternBindingSyntax, varName: String, parent: String?, access: AccessLevel, isStatic: Bool, isGlobal: Bool) {
        guard let accessorBlock = binding.accessorBlock,
              case .accessors(let accessors) = accessorBlock.accessors else { return }

        let varType: [String]? = binding.typeAnnotation.flatMap { annotation in
            if let dep = resolveTypeToDependency(annotation.type) {
                return [dep]
            }
            return nil
        }

        for accessor in accessors {
            let kind = accessor.accessorSpecifier.text
            guard kind == "willSet" || kind == "didSet" else { continue }
            let subKind: SymbolSubKind = kind == "willSet" ? .willSet : .didSet
            let name = "\(varName).\(kind)"
            let id = makeID(parent: parent, name: name)
            let loc = sourceLocation(of: accessor)
            symbols.append(SymbolInfo(id: id, name: name, flavor: .variable, subKind: subKind, isStatic: isStatic, isGlobal: isGlobal, isNested: false, isInteresting: true, resolvedType: nil, parentFile: isGlobal ? fileName : nil, sourceFile: fileName, access: access, parent: parent, location: loc, signature: nil, isProtocolRequirement: false, returnTypes: nil, parameterTypes: varType))
        }
    }

    private func extractResolvedType(binding: PatternBindingSyntax, node: VariableDeclSyntax) -> String? {
        if let typeAnnotation = binding.typeAnnotation {
            let raw = typeAnnotation.type.trimmedDescription
            let cleaned = raw.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: "!", with: "")
            if !cleaned.isEmpty && cleaned.first?.isUppercase == true { return cleaned }
        }
        if let initializer = binding.initializer {
            let initExpr = initializer.value
            if let funcCall = initExpr.as(FunctionCallExprSyntax.self) {
                if let ident = funcCall.calledExpression.as(DeclReferenceExprSyntax.self) {
                    let name = ident.baseName.text
                    if name.first?.isUppercase == true { return name }
                }
            }
        }
        return nil
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

    private func makeID(parent: String?, name: String, signature: String? = nil) -> String {
        let fullName = signature.map { "\(name)\($0)" } ?? name
        if let parent { return "\(parent).\(fullName)" }
        return fullName
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

    private func extractSignature(from clause: FunctionParameterClauseSyntax) -> String? {
        let params = clause.parameters
        if params.isEmpty { return "()" }
        let labels = params.map { param -> String in
            let label = param.firstName.text
            if label == "_" { return "_:" }
            return "\(label):"
        }
        return "(\(labels.joined()))"
    }

    private func extractReturnTypes(from clause: ReturnClauseSyntax?) -> [String]? {
        guard let clause else { return nil }
        let typeStr = clause.type.trimmedDescription
        return extractTypeNames(from: typeStr)
    }

    private func extractParameterTypes(from clause: FunctionParameterClauseSyntax) -> [String]? {
        let params = clause.parameters
        if params.isEmpty { return nil }
        var types: [String] = []
        for param in params {
            let typeStr = param.type.trimmedDescription
                .replacingOccurrences(of: "?", with: "")
                .replacingOccurrences(of: "!", with: "")
                .replacingOccurrences(of: "inout ", with: "")
            for t in extractTypeNames(from: typeStr) {
                types.append(t)
            }
        }
        return types.isEmpty ? nil : types
    }

    private func extractAllTypes(from typeSyntax: TypeSyntax) -> [String] {
        var results: [String] = []

        if let ident = typeSyntax.as(IdentifierTypeSyntax.self) {
            let name = ident.name.text
            if !Self.swiftStdlibTypes.contains(name) {
                results.append(name)
            }
            if let generics = ident.genericArgumentClause {
                for arg in generics.arguments {
                    results.append(contentsOf: extractAllTypes(from: arg.argument))
                }
            }
        } else if let optional = typeSyntax.as(OptionalTypeSyntax.self) {
            results.append(contentsOf: extractAllTypes(from: optional.wrappedType))
        } else if let implicitOptional = typeSyntax.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            results.append(contentsOf: extractAllTypes(from: implicitOptional.wrappedType))
        } else if let array = typeSyntax.as(ArrayTypeSyntax.self) {
            results.append(contentsOf: extractAllTypes(from: array.element))
        } else if let dict = typeSyntax.as(DictionaryTypeSyntax.self) {
            results.append(contentsOf: extractAllTypes(from: dict.key))
            results.append(contentsOf: extractAllTypes(from: dict.value))
        } else if let tuple = typeSyntax.as(TupleTypeSyntax.self) {
            for element in tuple.elements {
                results.append(contentsOf: extractAllTypes(from: element.type))
            }
        } else if let member = typeSyntax.as(MemberTypeSyntax.self) {
            results.append(contentsOf: extractAllTypes(from: TypeSyntax(member.baseType)))
            let name = member.name.text
            if !Self.swiftStdlibTypes.contains(name) {
                results.append(name)
            }
        } else if let funcType = typeSyntax.as(FunctionTypeSyntax.self) {
            for param in funcType.parameters {
                results.append(contentsOf: extractAllTypes(from: param.type))
            }
            results.append(contentsOf: extractAllTypes(from: funcType.returnClause.type))
        } else {
            let fallback = extractTypeNames(from: typeSyntax.trimmedDescription)
            results.append(contentsOf: fallback.filter { !Self.swiftStdlibTypes.contains($0) })
        }

        return results
    }

    private func resolveTypeToDependency(_ type: TypeSyntax) -> String? {
        let raw = type.trimmedDescription
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "inout ", with: "")

        let names = extractTypeNames(from: raw)
        if names.isEmpty { return nil }

        var resolved: [String] = []
        for name in names {
            if Self.swiftStdlibTypes.contains(name) { continue }

            if let ext = externalTargets.first(where: { name.contains($0) || $0 == name }) {
                if !resolved.contains(ext) { resolved.append(ext) }
                continue
            }

            let fullId = currentTarget.isEmpty ? name : "\(currentTarget)::\(name)"
            if !resolved.contains(fullId) { resolved.append(fullId) }
        }

        return resolved.isEmpty ? nil : resolved.joined(separator: ", ")
    }

    private static let swiftStdlibTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "String", "Character", "Bool", "Double", "Float", "Float16",
        "Void", "Never", "Any", "AnyObject", "AnyHashable",
        "Error", "Optional", "Array", "Dictionary", "Set",
        "Result", "Range", "ClosedRange", "Data", "Date", "URL",
        "Codable", "Encodable", "Decodable", "Hashable", "Equatable", "Comparable",
        "Identifiable", "Sendable", "CustomStringConvertible",
    ]

    private func extractTypeNames(from typeStr: String) -> [String] {
        let cleaned = typeStr
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "@escaping ", with: "")
            .replacingOccurrences(of: "@autoclosure ", with: "")
            .replacingOccurrences(of: "@Sendable ", with: "")
            .replacingOccurrences(of: "some ", with: "")
            .replacingOccurrences(of: "any ", with: "")

        var names: [String] = []
        let tokens = cleaned.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.first?.isUppercase == true else { continue }
            if Self.swiftStdlibTypes.contains(trimmed) { continue }
            names.append(trimmed)
        }
        return names
    }
}
