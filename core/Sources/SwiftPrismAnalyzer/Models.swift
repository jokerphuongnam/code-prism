import Foundation

struct AnalysisResult: Encodable {
    let nodes: [Node]
    let links: [Link]
    let resources: [ResourceNode]
    let targets: [TargetInfo]
    let macros: [MacroNode]
}

struct Node: Encodable {
    let id: String
    let name: String
    let flavor: SymbolFlavor
    let subKind: SymbolSubKind?
    let isStatic: Bool
    let access: AccessLevel
    let parent: String?
    let location: SourceLocation
    let targetName: String?
}

struct ResourceNode: Encodable {
    let id: String
    let name: String
    let resourceType: ResourceType
    let catalogName: String?
    let filePath: String
}

struct TargetInfo: Encodable {
    let name: String
    let type: TargetType
    let path: String
    let dependencies: [String]
}

struct MacroNode: Encodable {
    let id: String
    let name: String
    let macroType: MacroType
    let role: MacroRole?
    let conformances: [String]
    let generatedSymbols: [String]
    let location: SourceLocation
    let targetName: String?
}

struct Link: Encodable {
    let sourceId: String
    let targetId: String
    let type: LinkType
    let confidence: LinkConfidence?

    enum CodingKeys: String, CodingKey {
        case sourceId = "source_id"
        case targetId = "target_id"
        case type
        case confidence
    }
}

struct SourceLocation: Encodable {
    let file: String
    let line: Int
    let column: Int
}

enum SymbolFlavor: String, Encodable {
    case `struct`
    case `class`
    case `enum`
    case `actor`
    case `protocol`
    case function
    case variable
    case initializer
    case macro
}

enum SymbolSubKind: String, Encodable {
    case willSet
    case didSet
    case getter
    case setter
    case computed
    case stored
}

enum AccessLevel: String, Encodable {
    case `open`
    case `public`
    case `internal`
    case `fileprivate`
    case `private`
    case `package`
}

enum LinkType: String, Encodable {
    case call
    case access
    case conformance
    case inheritance
    case observerTrigger = "observer_trigger"
    case resourceLink = "resource_link"
    case resourceAlias = "resource_alias"
    case heuristicLink = "heuristic_link"
    case crossTargetDependency = "cross_target_dependency"
    case macroExpansion = "macro_expansion"
}

enum LinkConfidence: String, Encodable {
    case high
    case medium
    case low
}

enum ResourceType: String, Encodable {
    case imageSet = "image_set"
    case colorSet = "color_set"
    case dataSet = "data_set"
    case assetCatalog = "asset_catalog"
    case jsonFile = "json_file"
    case plistFile = "plist_file"
    case markdownFile = "markdown_file"
    case otherFile = "other_file"
}

enum TargetType: String, Encodable {
    case executable
    case library
    case testTarget = "test"
    case macroTarget = "macro"
    case plugin
    case unknown
}

enum MacroType: String, Encodable {
    case attached
    case freestanding
}

enum MacroRole: String, Encodable {
    case peer
    case member
    case accessor
    case memberAttribute
    case conformance
    case expression
    case declaration
    case codeItem
    case `extension`
    case body
    case preamble
}

struct SymbolInfo {
    let id: String
    let name: String
    let flavor: SymbolFlavor
    let subKind: SymbolSubKind?
    let isStatic: Bool
    let access: AccessLevel
    let parent: String?
    let location: SourceLocation
    var targetName: String?
}

struct CallRef {
    let callee: String
    let isQualified: Bool
    let qualifier: String?
}

struct ResourceRef {
    let resourceName: String
    let callContext: String
    let confidence: LinkConfidence
    let location: SourceLocation
}

struct StaticResourceAlias {
    let symbolId: String
    let resourceName: String
    let resourceKind: StaticResourceKind
}

enum StaticResourceKind {
    case image
    case color
}

struct ParsedTarget {
    let name: String
    let type: TargetType
    let path: String
    let sourcePaths: [String]
    let dependencies: [String]
}
