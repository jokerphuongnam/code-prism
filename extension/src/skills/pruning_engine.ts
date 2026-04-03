import type {
  PrismNode,
  PrismLink,
  AnalysisResult,
  SymbolFlavor,
  LinkType,
} from "../protocol";
import type * as vscode from "vscode";

interface ExecutionChainResult {
  executionChain: string[];
  visitedFiles: Set<string>;
}

interface PruningSymbol {
  id: string;
  name: string;
  flavor: SymbolFlavor;
  status: "required" | "redundant";
}

interface PruningManifest {
  requiredSymbols: string[];
  prunedSymbols: string[];
  activeFrameworks: string[];
}

interface NodeSummary {
  id: string;
  name: string;
  flavor: SymbolFlavor;
  isVisibleInGraph: boolean;
  impactScore: "high" | "low";
}

type NodeIndex = Map<string, PrismNode>;
type LinkIndex = Map<string, PrismLink[]>;
type FileNodeIndex = Map<string, PrismNode[]>;

const ENVIRONMENT_LINK_TYPES: ReadonlySet<LinkType> = new Set([
  "environment_injection",
  "environment_provider",
]);

const HIGH_IMPACT_SUBKINDS: ReadonlySet<string> = new Set([
  "computed",
  "willSet",
  "didSet",
  "getter",
  "setter",
]);

const CALLSITE_LINK_TYPES: ReadonlySet<LinkType> = new Set([
  "call",
  "access",
  "observer_trigger",
  "macro_expansion",
  "extension_contribution",
]);

function buildNodeIndex(nodes: PrismNode[]): NodeIndex {
  const index: NodeIndex = new Map();
  for (const node of nodes) {
    index.set(node.id, node);
  }
  return index;
}

function buildLinkIndex(links: PrismLink[]): LinkIndex {
  const index: LinkIndex = new Map();
  for (const link of links) {
    const existing = index.get(link.source_id);
    if (existing) {
      existing.push(link);
    } else {
      index.set(link.source_id, [link]);
    }
  }
  return index;
}

function buildFileNodeIndex(nodes: PrismNode[]): FileNodeIndex {
  const index: FileNodeIndex = new Map();
  for (const node of nodes) {
    const existing = index.get(node.sourceFile);
    if (existing) {
      existing.push(node);
    } else {
      index.set(node.sourceFile, [node]);
    }
  }
  return index;
}

function resolveEnvironmentProviders(
  targetTypeName: string,
  nodes: PrismNode[],
  links: PrismLink[]
): string[] {
  const providerIds: string[] = [];
  for (const link of links) {
    if (!ENVIRONMENT_LINK_TYPES.has(link.type)) {
      continue;
    }
    const sourceNode = nodes.find((n) => n.id === link.source_id);
    if (sourceNode && sourceNode.name === targetTypeName) {
      providerIds.push(link.target_id);
    }
    const targetNode = nodes.find((n) => n.id === link.target_id);
    if (targetNode && targetNode.name === targetTypeName) {
      providerIds.push(link.source_id);
    }
  }
  return providerIds;
}

function classifyImpact(node: PrismNode): "high" | "low" {
  if (node.subKind && HIGH_IMPACT_SUBKINDS.has(node.subKind)) {
    return "high";
  }
  if (node.flavor === "function" || node.flavor === "initializer") {
    return "high";
  }
  return "low";
}

function isVisibleSymbol(node: PrismNode): boolean {
  if (!node.isInteresting) return false;
  if (node.flavor === "variable" && node.subKind === "stored" && !node.isStatic) {
    return false;
  }
  return true;
}

function extractImportedFrameworks(
  fileNodes: PrismNode[],
  allLinks: PrismLink[]
): string[] {
  const frameworks: Set<string> = new Set();
  for (const node of fileNodes) {
    const outgoing = allLinks.filter((l) => l.source_id === node.id);
    for (const link of outgoing) {
      if (link.type === "cross_target_dependency") {
        frameworks.add(link.target_id);
      }
    }
  }
  return Array.from(frameworks);
}

export class PruningEngineService {
  private readonly nodeIndex: NodeIndex;
  private readonly linkIndex: LinkIndex;
  private readonly fileNodeIndex: FileNodeIndex;
  private readonly analysisResult: AnalysisResult;
  private readonly webview: vscode.Webview | null;

  constructor(analysisResult: AnalysisResult, webview?: vscode.Webview) {
    this.analysisResult = analysisResult;
    this.nodeIndex = buildNodeIndex(analysisResult.nodes);
    this.linkIndex = buildLinkIndex(analysisResult.links);
    this.fileNodeIndex = buildFileNodeIndex(analysisResult.nodes);
    this.webview = webview ?? null;
  }

  analyzeExecutionChain(rootNodeId: string): ExecutionChainResult {
    const visited = new Set<string>();
    const visitedFiles = new Set<string>();
    const chain: string[] = [];

    this.dfsTrace(rootNodeId, visited, visitedFiles, chain);

    return { executionChain: chain, visitedFiles };
  }

  getPruningManifest(targetFile: string): PruningManifest {
    const fileNodes = this.fileNodeIndex.get(targetFile) ?? [];
    if (fileNodes.length === 0) {
      return { requiredSymbols: [], prunedSymbols: [], activeFrameworks: [] };
    }

    const rootNode = fileNodes.find(
      (n) => n.flavor === "struct" || n.flavor === "class" || n.flavor === "enum"
    );
    if (!rootNode) {
      return {
        requiredSymbols: fileNodes.map((n) => n.id),
        prunedSymbols: [],
        activeFrameworks: extractImportedFrameworks(fileNodes, this.analysisResult.links),
      };
    }

    const { executionChain } = this.analyzeExecutionChain(rootNode.id);
    const chainSet = new Set(executionChain);

    const requiredSymbols: string[] = [];
    const prunedSymbols: string[] = [];

    for (const node of fileNodes) {
      if (chainSet.has(node.id)) {
        requiredSymbols.push(node.id);
      } else {
        prunedSymbols.push(node.id);
      }
    }

    const allFrameworks = extractImportedFrameworks(fileNodes, this.analysisResult.links);
    const activeFrameworks = allFrameworks.filter((framework) =>
      this.hasRequiredSymbolFromFramework(framework, chainSet)
    );

    return { requiredSymbols, prunedSymbols, activeFrameworks };
  }

  getNodeSummaries(nodeIds: string[]): NodeSummary[] {
    return nodeIds.reduce<NodeSummary[]>((summaries, id) => {
      const node = this.nodeIndex.get(id);
      if (node) {
        summaries.push({
          id: node.id,
          name: node.name,
          flavor: node.flavor,
          isVisibleInGraph: isVisibleSymbol(node),
          impactScore: classifyImpact(node),
        });
      }
      return summaries;
    }, []);
  }

  resolveWebviewUri(filePath: string): string {
    if (this.webview) {
      const uri = { scheme: "file", path: filePath } as vscode.Uri;
      return this.webview.asWebviewUri(uri).toString();
    }
    return filePath;
  }

  private dfsTrace(
    nodeId: string,
    visited: Set<string>,
    visitedFiles: Set<string>,
    chain: string[]
  ): void {
    if (visited.has(nodeId)) {
      return;
    }
    visited.add(nodeId);
    chain.push(nodeId);

    const node = this.nodeIndex.get(nodeId);
    if (node) {
      visitedFiles.add(node.sourceFile);
    }

    const outgoingLinks = this.linkIndex.get(nodeId) ?? [];

    for (const link of outgoingLinks) {
      if (CALLSITE_LINK_TYPES.has(link.type) || ENVIRONMENT_LINK_TYPES.has(link.type)) {
        this.dfsTrace(link.target_id, visited, visitedFiles, chain);
      }

      if (ENVIRONMENT_LINK_TYPES.has(link.type)) {
        const targetNode = this.nodeIndex.get(link.target_id);
        if (targetNode) {
          const providers = resolveEnvironmentProviders(
            targetNode.name,
            this.analysisResult.nodes,
            this.analysisResult.links
          );
          for (const providerId of providers) {
            this.dfsTrace(providerId, visited, visitedFiles, chain);
          }
        }
      }
    }

    if (node && (node.flavor === "struct" || node.flavor === "class")) {
      const members = this.analysisResult.nodes.filter(
        (n) => n.parent === node.id
      );
      for (const member of members) {
        if (member.flavor === "initializer") {
          this.dfsTrace(member.id, visited, visitedFiles, chain);
        }
        const memberLinks = this.linkIndex.get(member.id) ?? [];
        for (const memberLink of memberLinks) {
          if (CALLSITE_LINK_TYPES.has(memberLink.type)) {
            this.dfsTrace(memberLink.target_id, visited, visitedFiles, chain);
          }
        }
      }
    }
  }

  private hasRequiredSymbolFromFramework(
    framework: string,
    requiredSet: Set<string>
  ): boolean {
    for (const link of this.analysisResult.links) {
      if (link.type !== "cross_target_dependency") {
        continue;
      }
      if (link.target_id !== framework) {
        continue;
      }
      if (requiredSet.has(link.source_id)) {
        return true;
      }
    }
    return false;
  }
}
