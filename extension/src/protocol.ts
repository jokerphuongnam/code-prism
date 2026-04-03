export type SymbolFlavor =
  | "struct"
  | "class"
  | "enum"
  | "actor"
  | "protocol"
  | "function"
  | "variable"
  | "initializer"
  | "macro"
  | "entry_point";

export type SymbolSubKind =
  | "willSet"
  | "didSet"
  | "getter"
  | "setter"
  | "computed"
  | "stored";

export type AccessLevel =
  | "open"
  | "public"
  | "internal"
  | "fileprivate"
  | "private"
  | "package";

export type LinkType =
  | "call"
  | "access"
  | "conformance"
  | "inheritance"
  | "observer_trigger"
  | "resource_link"
  | "resource_alias"
  | "heuristic_link"
  | "cross_target_dependency"
  | "macro_expansion"
  | "extension_contribution"
  | "nesting"
  | "environment_injection"
  | "environment_provider"
  | "holds_type"
  | "enum_usage";

export type LinkConfidence = "high" | "medium" | "low";

export type ResourceType =
  | "image_set"
  | "color_set"
  | "data_set"
  | "asset_catalog"
  | "json_file"
  | "plist_file"
  | "markdown_file"
  | "strings_file"
  | "localization"
  | "other_file";

export type TargetType =
  | "executable"
  | "library"
  | "test"
  | "macro"
  | "plugin"
  | "unknown";

export type MacroType = "attached" | "freestanding";

export interface SourceLocation {
  file: string;
  line: number;
  column: number;
}

export interface PrismNode {
  id: string;
  name: string;
  flavor: SymbolFlavor;
  subKind: SymbolSubKind | null;
  isStatic: boolean;
  isGlobal: boolean;
  isNested: boolean;
  isInteresting: boolean;
  access: AccessLevel;
  parent: string | null;
  parentFile: string | null;
  sourceFile: string;
  location: SourceLocation;
  targetName: string | null;
  memberCount: number | null;
}

export interface ResourceNode {
  id: string;
  name: string;
  resourceType: ResourceType;
  catalogName: string | null;
  parentGroup: string | null;
  filePath: string;
}

export interface TargetInfo {
  name: string;
  type: TargetType;
  path: string;
  dependencies: string[];
}

export interface MacroNode {
  id: string;
  name: string;
  macroType: MacroType;
  role: string | null;
  conformances: string[];
  generatedSymbols: string[];
  location: SourceLocation;
  targetName: string | null;
}

export interface CallSiteRef {
  line: number;
  column: number;
  snippet: string;
  file: string;
}

export interface PrismLink {
  source_id: string;
  target_id: string;
  type: LinkType;
  confidence: LinkConfidence | null;
  references: CallSiteRef[] | null;
}

export interface ModuleNode {
  id: string;
  name: string;
  moduleType: TargetType;
  isMacro: boolean;
  symbolCount: number;
  publicSymbolCount: number;
}

export interface AnalysisResult {
  projectRoot: string | null;
  nodes: PrismNode[];
  links: PrismLink[];
  resources: ResourceNode[];
  targets: TargetInfo[];
  macros: MacroNode[];
  moduleNodes: ModuleNode[] | null;
}

export type AnalysisPhase =
  | "idle"
  | "scanning"
  | "targets"
  | "resources"
  | "macros"
  | "resolving"
  | "encoding"
  | "streaming"
  | "complete"
  | "error";

export interface ProgressInfo {
  phase: AnalysisPhase;
  processed: number;
  total: number;
}
