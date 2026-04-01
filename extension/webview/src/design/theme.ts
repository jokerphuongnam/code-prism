import type { SymbolFlavor, SymbolSubKind, LinkType, LinkConfidence, ResourceType } from "../protocol";

const FLAVOR_COLORS: Record<SymbolFlavor, string> = {
  struct: "#4FC3F7",
  class: "#7E57C2",
  enum: "#FF8A65",
  actor: "#26A69A",
  protocol: "#FFD54F",
  function: "#42A5F5",
  variable: "#66BB6A",
  initializer: "#AB47BC",
  macro: "#FF7043",
};

const SUBKIND_COLORS: Partial<Record<SymbolSubKind, string>> = {
  didSet: "#E040FB",
  willSet: "#F48FB1",
  computed: "#81D4FA",
  getter: "#A5D6A7",
  setter: "#EF9A9A",
};

const RESOURCE_COLORS: Record<ResourceType, string> = {
  image_set: "#29B6F6",
  color_set: "#EC407A",
  data_set: "#78909C",
  asset_catalog: "#5C6BC0",
  json_file: "#FFA726",
  plist_file: "#8D6E63",
  markdown_file: "#26C6DA",
  other_file: "#BDBDBD",
};

export function nodeColor(
  flavor: SymbolFlavor,
  subKind: SymbolSubKind | null
): string {
  if (subKind && SUBKIND_COLORS[subKind]) {
    return SUBKIND_COLORS[subKind]!;
  }
  return FLAVOR_COLORS[flavor];
}

export function resourceColor(resourceType: ResourceType): string {
  return RESOURCE_COLORS[resourceType];
}

export type NodeShape = "sphere" | "box" | "diamond" | "mini-sphere" | "cylinder" | "cone" | "torus" | "large-box";

export function nodeShape(
  flavor: SymbolFlavor,
  subKind: SymbolSubKind | null,
  isStatic: boolean
): NodeShape {
  if (subKind === "willSet" || subKind === "didSet") return "mini-sphere";
  if (subKind === "computed") return "diamond";
  if (isStatic) return "box";
  return "sphere";
}

export function resourceShape(resourceType: ResourceType): NodeShape {
  switch (resourceType) {
    case "asset_catalog":
      return "large-box";
    case "image_set":
      return "cylinder";
    case "color_set":
      return "cone";
    case "json_file":
    case "plist_file":
      return "diamond";
    case "markdown_file":
      return "torus";
    default:
      return "box";
  }
}

export function nodeSize(flavor: SymbolFlavor, subKind: SymbolSubKind | null): number {
  if (subKind === "willSet" || subKind === "didSet") return 3;
  switch (flavor) {
    case "struct":
    case "class":
    case "actor":
    case "protocol":
    case "enum":
      return 8;
    case "function":
    case "initializer":
      return 5;
    case "variable":
      return 4;
    case "macro":
      return 7;
  }
}

export function resourceSize(resourceType: ResourceType): number {
  switch (resourceType) {
    case "asset_catalog":
      return 12;
    case "image_set":
    case "color_set":
      return 6;
    default:
      return 5;
  }
}

const LINK_COLORS: Record<LinkType, string> = {
  call: "#90CAF9",
  access: "#A5D6A7",
  conformance: "#FFD54F",
  inheritance: "#CE93D8",
  observer_trigger: "#F48FB1",
  resource_link: "#29B6F6",
  resource_alias: "#7E57C2",
  heuristic_link: "#FFB74D",
  cross_target_dependency: "#EF5350",
  macro_expansion: "#FF7043",
};

export function linkColor(type: LinkType): string {
  return LINK_COLORS[type];
}

export function linkDashArray(type: LinkType): number[] | null {
  switch (type) {
    case "conformance":
    case "observer_trigger":
      return [4, 4];
    case "inheritance":
      return [8, 4];
    case "resource_link":
      return [6, 3];
    case "resource_alias":
      return [3, 3];
    case "heuristic_link":
      return [2, 4];
    case "cross_target_dependency":
      return [10, 4];
    case "macro_expansion":
      return [5, 2];
    default:
      return null;
  }
}

export function linkWidth(type: LinkType): number {
  switch (type) {
    case "inheritance":
    case "conformance":
      return 2;
    case "resource_link":
    case "resource_alias":
      return 1.5;
    case "cross_target_dependency":
      return 2.5;
    case "macro_expansion":
      return 1.5;
    case "heuristic_link":
      return 1;
    default:
      return 1;
  }
}

const CONFIDENCE_COLORS: Record<LinkConfidence, string> = {
  high: "#66BB6A",
  medium: "#FFB74D",
  low: "#EF5350",
};

export function confidenceColor(confidence: LinkConfidence): string {
  return CONFIDENCE_COLORS[confidence];
}

export function confidenceLabel(confidence: LinkConfidence): string {
  switch (confidence) {
    case "high":
      return "High";
    case "medium":
      return "Medium";
    case "low":
      return "Low";
  }
}
