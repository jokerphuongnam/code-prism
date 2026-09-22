import Foundation
import SwiftSyntax
import SwiftParser

struct PackageManifestParser {

    let packagePath: String

    func parse() -> [ParsedTarget] {
        let manifestFile = (packagePath as NSString).appendingPathComponent("Package.swift")
        guard let data = FileManager.default.contents(atPath: manifestFile),
              let source = String(data: data, encoding: .utf8) else {
            return []
        }

        let tree = Parser.parse(source: source)
        let collector = ManifestTargetCollector(basePath: packagePath)
        collector.walk(tree)
        return collector.targets
    }
}

private final class ManifestTargetCollector: SyntaxVisitor {

    private(set) var targets: [ParsedTarget] = []
    private let basePath: String

    init(basePath: String) {
        self.basePath = basePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }

        let method = memberAccess.declName.baseName.text
        let targetType = classifyTargetMethod(method)
        guard let targetType else { return .visitChildren }

        let name = extractStringArg(from: node, label: "name") ?? extractFirstStringArg(from: node)
        guard let name else { return .visitChildren }

        let customPath = extractStringArg(from: node, label: "path")
        let resolvedPath = resolveTargetPath(name: name, customPath: customPath, type: targetType)
        let dependencies = extractDependencies(from: node)

        targets.append(ParsedTarget(
            name: name,
            type: targetType,
            path: resolvedPath,
            sourcePaths: discoverSwiftFiles(in: resolvedPath),
            dependencies: dependencies
        ))

        return .skipChildren
    }

    private func classifyTargetMethod(_ method: String) -> TargetType? {
        switch method {
        case "executableTarget": return .executable
        case "target": return .library
        case "testTarget": return .testTarget
        case "macro": return .macroTarget
        case "plugin": return .plugin
        default: return nil
        }
    }

    private func resolveTargetPath(name: String, customPath: String?, type: TargetType) -> String {
        if let customPath {
            return (basePath as NSString).appendingPathComponent(customPath)
        }
        let defaultDir: String
        switch type {
        case .testTarget:
            defaultDir = "Tests"
        default:
            defaultDir = "Sources"
        }
        return ((basePath as NSString).appendingPathComponent(defaultDir) as NSString).appendingPathComponent(name)
    }

    private func extractDependencies(from call: FunctionCallExprSyntax) -> [String] {
        var deps: [String] = []
        for arg in call.arguments {
            guard arg.label?.text == "dependencies" else { continue }
            guard let arrayExpr = arg.expression.as(ArrayExprSyntax.self) else { continue }
            for element in arrayExpr.elements {
                if let stringLit = element.expression.as(StringLiteralExprSyntax.self) {
                    if let name = extractPlainString(stringLit) {
                        deps.append(name)
                    }
                }
                if let funcCall = element.expression.as(FunctionCallExprSyntax.self) {
                    if let name = extractFirstStringArg(from: funcCall) {
                        deps.append(name)
                    }
                    if let memberAccess = funcCall.calledExpression.as(MemberAccessExprSyntax.self) {
                        let method = memberAccess.declName.baseName.text
                        if method == "product" || method == "target" || method == "byName" {
                            if let name = extractStringArg(from: funcCall, label: "name") {
                                deps.append(name)
                            }
                        }
                    }
                }
            }
        }
        return deps
    }

    private func extractStringArg(from call: FunctionCallExprSyntax, label: String) -> String? {
        for arg in call.arguments {
            guard arg.label?.text == label else { continue }
            guard let stringLit = arg.expression.as(StringLiteralExprSyntax.self) else { continue }
            return extractPlainString(stringLit)
        }
        return nil
    }

    private func extractFirstStringArg(from call: FunctionCallExprSyntax) -> String? {
        for arg in call.arguments {
            guard let stringLit = arg.expression.as(StringLiteralExprSyntax.self) else { continue }
            return extractPlainString(stringLit)
        }
        return nil
    }

    private func extractPlainString(_ node: StringLiteralExprSyntax) -> String? {
        guard node.segments.count == 1,
              let segment = node.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return segment.content.text
    }

    private func discoverSwiftFiles(in directory: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append(url.path)
            }
        }
        return files.sorted()
    }
}
