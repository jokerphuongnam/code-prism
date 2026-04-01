export type SymbolFlavor =
  | "struct"
  | "class"
  | "enum"
  | "actor"
  | "protocol"
  | "function"
  | "variable"
  | "initializer"
  | "macro";

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
  | "macro_expansion";

export type LinkConfidence = "high" | "medium" | "low";

export type ResourceType =
  | "image_set"
  | "color_set"
  | "data_set"
  | "asset_catalog"
  | "json_file"
  | "plist_file"
  | "markdown_file"
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
  access: AccessLevel;
  parent: string | null;
  location: SourceLocation;
  targetName: string | null;
}

export interface ResourceNode {
  id: string;
  name: string;
  resourceType: ResourceType;
  catalogName: string | null;
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

export interface PrismLink {
  source_id: string;
  target_id: string;
  type: LinkType;
  confidence: LinkConfidence | null;
}

export interface AnalysisResult {
  nodes: PrismNode[];
  links: PrismLink[];
  resources: ResourceNode[];
  targets: TargetInfo[];
  macros: MacroNode[];
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
