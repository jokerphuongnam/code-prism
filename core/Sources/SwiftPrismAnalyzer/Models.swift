import Foundation

struct AnalysisResult: Encodable {
    let projectRoot: String?
    let nodes: [Node]
    let links: [Link]
    let resources: [ResourceNode]
    let targets: [TargetInfo]
    let macros: [MacroNode]
    let moduleNodes: [ModuleNode]?
}

struct ModuleNode: Encodable {
    let id: String
    let name: String
    let moduleType: TargetType
    let isMacro: Bool
    let symbolCount: Int
    let publicSymbolCount: Int
}

struct Node: Encodable {
    let id: String
    let name: String
    let flavor: SymbolFlavor
    let subKind: SymbolSubKind?
    let isStatic: Bool
    let isGlobal: Bool
    let isNested: Bool
    let isInteresting: Bool
    let access: AccessLevel
    let parent: String?
    let parentFile: String?
    let sourceFile: String
    let location: SourceLocation
    let targetName: String?
    let memberCount: Int?
    let parents: [String]?
    let implementers: [String]?
    let superClass: String?
    let extensions: [String]?
    let signature: String?
    let isProtocolRequirement: Bool
    let returnTypes: [String]?
    let parameterTypes: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, flavor, location, targetName
        case subKind, isStatic, isGlobal, isNested, isInteresting
        case isProtocolRequirement, returnTypes, parameterTypes
        case access, parent, parentFile, sourceFile, memberCount
        case parents, implementers, superClass, extensions, signature
    }

    init(id: String, name: String, flavor: SymbolFlavor, subKind: SymbolSubKind?,
         isStatic: Bool, isGlobal: Bool, isNested: Bool, isInteresting: Bool,
         access: AccessLevel, parent: String?, parentFile: String?, sourceFile: String,
         location: SourceLocation, targetName: String?, memberCount: Int?,
         parents: [String]?, implementers: [String]?, superClass: String?,
         extensions: [String]?, signature: String? = nil,
         isProtocolRequirement: Bool = false,
         returnTypes: [String]? = nil, parameterTypes: [String]? = nil) {
        self.id = id; self.name = name; self.flavor = flavor; self.subKind = subKind
        self.isStatic = isStatic; self.isGlobal = isGlobal; self.isNested = isNested
        self.isInteresting = isInteresting; self.access = access; self.parent = parent
        self.parentFile = parentFile; self.sourceFile = sourceFile; self.location = location
        self.targetName = targetName; self.memberCount = memberCount; self.parents = parents
        self.implementers = implementers; self.superClass = superClass
        self.extensions = extensions; self.signature = signature
        self.isProtocolRequirement = isProtocolRequirement
        self.returnTypes = returnTypes; self.parameterTypes = parameterTypes
    }
}

struct ResourceNode: Encodable {
    let id: String
    let name: String
    let resourceType: ResourceType
    let catalogName: String?
    let parentGroup: String?
    let filePath: String
}

struct TargetInfo: Encodable {
    let name: String
    let type: TargetType
    let path: String
    let dependencies: [String]
    let isExternal: Bool
    let remoteURL: String?

    init(name: String, type: TargetType, path: String, dependencies: [String], isExternal: Bool = false, remoteURL: String? = nil) {
        self.name = name; self.type = type; self.path = path
        self.dependencies = dependencies; self.isExternal = isExternal; self.remoteURL = remoteURL
    }
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

struct CallSiteRef: Encodable {
    let line: Int
    let column: Int
    let snippet: String
    let file: String
}

struct Link: Encodable {
    let sourceId: String
    let targetId: String
    let type: LinkType
    let confidence: LinkConfidence?
    let references: [CallSiteRef]?

    enum CodingKeys: String, CodingKey {
        case sourceId = "source_id"
        case targetId = "target_id"
        case type
        case confidence
        case references
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
    case entryPoint = "entry_point"
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
    case extensionContribution = "extension_contribution"
    case nesting
    case environmentInjection = "environment_injection"
    case environmentProvider = "environment_provider"
    case holdsType = "holds_type"
    case enumUsage = "enum_usage"
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
    case stringsFile = "strings_file"
    case localization = "localization"
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
    let isGlobal: Bool
    let isNested: Bool
    let isInteresting: Bool
    let resolvedType: String?
    let parentFile: String?
    let sourceFile: String
    let access: AccessLevel
    let parent: String?
    let location: SourceLocation
    var targetName: String?
    let signature: String?
    let isProtocolRequirement: Bool
    let returnTypes: [String]?
    let parameterTypes: [String]?
}

struct CallRef {
    let callee: String
    let isQualified: Bool
    let qualifier: String?
    let callSignature: String?
    let line: Int
    let column: Int
    let snippet: String
    let file: String
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
    let isExternal: Bool
    let remoteURL: String?

    init(name: String, type: TargetType, path: String, sourcePaths: [String], dependencies: [String], isExternal: Bool = false, remoteURL: String? = nil) {
        self.name = name; self.type = type; self.path = path
        self.sourcePaths = sourcePaths; self.dependencies = dependencies
        self.isExternal = isExternal; self.remoteURL = remoteURL
    }
}

struct FullSummary: Encodable {
    let version: String
    let generatedAt: String
    let symbols: [SymbolSummary]
    let deadCode: [DeadCodeEntry]
    let pruningStats: PruningStats
}

struct SymbolSummary: Encodable {
    let id: String
    let name: String
    let flavor: String
    let subKind: String?
    let isInteresting: Bool
    let isVisibleInGraph: Bool
    let parent: String?
    let sourceFile: String
    let line: Int
    let referenceCount: Int
    let referencedBy: [String]
    let references: [String]
}

struct DeadCodeEntry: Encodable {
    let id: String
    let name: String
    let flavor: String
    let sourceFile: String
    let line: Int
    let reason: String
    let suggestion: String
}

struct PruningStats: Encodable {
    let totalSymbols: Int
    let deadSymbols: Int
    let isolatedTypes: Int
    let writeOnlyProperties: Int
    let initOnlyProperties: Int
    let estimatedSavings: String
}

struct FocusAnalysis: Encodable {
    let rootId: String
    let requiredSymbols: [FocusSymbol]
    let requiredFiles: [String]
    let requiredFrameworks: [String]
    let redundantSymbols: [String]
    let unusedFrameworks: [String]
    let blastRadius: [String: [String]]
    let efficiency: FocusEfficiency
}

struct FocusSymbol: Encodable {
    let id: String
    let name: String
    let flavor: String
    let depth: Int
    let sourceFile: String
    let isStub: Bool
}

struct FocusEfficiency: Encodable {
    let requiredSymbolCount: Int
    let totalSymbolCount: Int
    let requiredFileCount: Int
    let totalFileCount: Int
    let requiredFrameworkCount: Int
    let totalFrameworkCount: Int
    let summary: String
}

struct FlatMapEntry: Encodable {
    let id: String
    let name: String
    let flavor: String
    let location: FlatLocation
    let parents: [String]
    var calls: [String]?
    var locations: [FlatObjectLocation]?
    var sourceFiles: [String]?
    var inits: [String]?
    var deinits: [String]?
    var `extends`: String?
    var implements: [String]?
    var returnTypes: [String]?
    var parameterTypes: [String]?
    var isProtocolRequirement: Bool = false

    private static let objectFlavors: Set<String> = ["struct", "class", "enum", "actor", "protocol"]
    private static let deinitFlavors: Set<String> = ["class", "actor"]

    enum CodingKeys: String, CodingKey {
        case id, name, flavor, location, parents
        case calls, locations, sourceFiles
        case inits, deinits
        case `extends`, implements
        case returnTypes = "returns"
        case parameterTypes = "parameters"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(flavor, forKey: .flavor)
        try c.encode(location, forKey: .location)
        try c.encode(parents, forKey: .parents)

        let isObject = Self.objectFlavors.contains(flavor)

        if isObject {
            try c.encode(locations ?? [], forKey: .locations)
            try c.encode(sourceFiles ?? [], forKey: .sourceFiles)
            try c.encode(inits ?? [], forKey: .inits)
            if Self.deinitFlavors.contains(flavor) {
                try c.encode(deinits ?? [], forKey: .deinits)
            }
            try c.encodeIfPresent(`extends`, forKey: .extends)
            try c.encode(implements ?? [], forKey: .implements)
        } else {
            if !isProtocolRequirement {
                try c.encode(calls ?? [], forKey: .calls)
            }
            if let returns = returnTypes, !returns.isEmpty {
                try c.encode(returns, forKey: .returnTypes)
            }
            if let params = parameterTypes, !params.isEmpty {
                try c.encode(params, forKey: .parameterTypes)
            }
        }
    }
}

struct FlatLocation: Encodable {
    let absPath: String
    let line: Int
    let col: Int
}

struct FlatObjectLocation: Encodable {
    let absPath: String
    let line: Int
    let col: Int
    let type: String
}
