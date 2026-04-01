import { useRef, useEffect, useCallback, useState } from "react";
import ForceGraph3D, { type ForceGraph3DInstance } from "3d-force-graph";
import * as THREE from "three";
import type { AnalysisResult, PrismNode, PrismLink } from "../protocol";
import {
  nodeColor,
  nodeShape,
  nodeSize,
  resourceColor,
  resourceShape,
  resourceSize,
  linkColor,
  linkWidth,
  type NodeShape,
} from "../design/theme";

interface GraphViewProps {
  result: AnalysisResult | null;
  highlightedIds?: Set<string>;
  onCopyContext?: (nodeId: string) => void;
}

interface GraphNode {
  id: string;
  name: string;
  flavor: PrismNode["flavor"] | "resource";
  subKind: PrismNode["subKind"];
  isStatic: boolean;
  color: string;
  shape: NodeShape;
  size: number;
  isHighlighted: boolean;
  x?: number;
  y?: number;
  z?: number;
}

interface GraphLink {
  source: string;
  target: string;
  linkType: PrismLink["type"];
  color: string;
  width: number;
}

function buildGraphData(
  result: AnalysisResult,
  highlightedIds: Set<string>
): { nodes: GraphNode[]; links: GraphLink[] } {
  const nodes: GraphNode[] = result.nodes.map((n) => ({
    id: n.id,
    name: n.name,
    flavor: n.flavor,
    subKind: n.subKind,
    isStatic: n.isStatic,
    color: nodeColor(n.flavor, n.subKind),
    shape: nodeShape(n.flavor, n.subKind, n.isStatic),
    size: nodeSize(n.flavor, n.subKind),
    isHighlighted: highlightedIds.has(n.id) || highlightedIds.has(n.name),
  }));

  if (result.resources) {
    for (const r of result.resources) {
      nodes.push({
        id: r.id,
        name: r.name,
        flavor: "resource",
        subKind: null,
        isStatic: false,
        color: resourceColor(r.resourceType),
        shape: resourceShape(r.resourceType),
        size: resourceSize(r.resourceType),
        isHighlighted: highlightedIds.has(r.id) || highlightedIds.has(r.name),
      });
    }
  }

  const nodeIds = new Set(nodes.map((n) => n.id));
  const links: GraphLink[] = result.links
    .filter((l) => nodeIds.has(l.source_id) && nodeIds.has(l.target_id))
    .map((l) => ({
      source: l.source_id,
      target: l.target_id,
      linkType: l.type,
      color: linkColor(l.type),
      width: linkWidth(l.type),
    }));

  return { nodes, links };
}

function createNodeGeometry(shape: NodeShape, size: number): THREE.BufferGeometry {
  switch (shape) {
    case "box":
      return new THREE.BoxGeometry(size, size, size);
    case "large-box":
      return new THREE.BoxGeometry(size * 1.2, size * 0.8, size * 1.2);
    case "diamond": {
      const geo = new THREE.OctahedronGeometry(size * 0.7);
      geo.scale(1, 1.4, 1);
      return geo;
    }
    case "mini-sphere":
      return new THREE.SphereGeometry(size * 0.5, 12, 8);
    case "cylinder":
      return new THREE.CylinderGeometry(size * 0.4, size * 0.4, size, 16);
    case "cone":
      return new THREE.ConeGeometry(size * 0.5, size, 16);
    case "torus":
      return new THREE.TorusGeometry(size * 0.4, size * 0.15, 12, 24);
    case "sphere":
    default:
      return new THREE.SphereGeometry(size * 0.5, 16, 12);
  }
}

export function GraphView({ result, highlightedIds = new Set(), onCopyContext }: GraphViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const graphRef = useRef<ForceGraph3DInstance | null>(null);
  const [selectedNode, setSelectedNode] = useState<GraphNode | null>(null);

  const initGraph = useCallback(() => {
    if (!containerRef.current) return;
    if (graphRef.current) graphRef.current._destructor();

    const graph = new ForceGraph3D(containerRef.current)
      .backgroundColor("rgba(0,0,0,0)")
      .showNavInfo(false)
      .nodeThreeObject((node: unknown) => {
        const n = node as GraphNode;
        const geometry = createNodeGeometry(n.shape, n.size);
        const material = new THREE.MeshLambertMaterial({
          color: n.isHighlighted ? "#FFFFFF" : n.color,
          transparent: true,
          opacity: n.isHighlighted ? 1.0 : 0.9,
          emissive: n.isHighlighted ? n.color : "#000000",
          emissiveIntensity: n.isHighlighted ? 0.5 : 0,
        });
        const mesh = new THREE.Mesh(geometry, material);
        if (n.isHighlighted) {
          const glowGeo = createNodeGeometry(n.shape, n.size * 1.4);
          const glowMat = new THREE.MeshBasicMaterial({ color: n.color, transparent: true, opacity: 0.2 });
          mesh.add(new THREE.Mesh(glowGeo, glowMat));
        }
        return mesh;
      })
      .nodeLabel((node: unknown) => {
        const n = node as GraphNode;
        const parts = [n.name];
        if (n.subKind) parts.push(`(${n.subKind})`);
        parts.push(`[${n.flavor}]`);
        if (n.isStatic) parts.push("static");
        return parts.join(" ");
      })
      .onNodeClick((node: unknown) => {
        setSelectedNode(node as GraphNode);
      })
      .linkColor((link: unknown) => (link as GraphLink).color)
      .linkWidth((link: unknown) => (link as GraphLink).width)
      .linkOpacity(0.6)
      .linkDirectionalArrowLength(4)
      .linkDirectionalArrowRelPos(1)
      .d3AlphaDecay(0.05)
      .d3VelocityDecay(0.3);

    graphRef.current = graph;
    return graph;
  }, []);

  useEffect(() => {
    const graph = initGraph();
    if (!graph || !result) return;
    const data = buildGraphData(result, highlightedIds);
    graph.graphData(data);

    const handleResize = () => {
      if (!containerRef.current) return;
      graph.width(containerRef.current.clientWidth).height(containerRef.current.clientHeight);
    };
    const observer = new ResizeObserver(handleResize);
    if (containerRef.current) observer.observe(containerRef.current);
    return () => observer.disconnect();
  }, [result, highlightedIds, initGraph]);

  if (!result) {
    return <div style={styles.empty}>Run analysis to see the dependency graph.</div>;
  }

  return (
    <div style={styles.wrapper}>
      <div ref={containerRef} style={styles.container} />
      {selectedNode && (
        <div style={styles.contextPanel}>
          <div style={styles.contextHeader}>
            <span style={styles.contextTitle}>{selectedNode.name}</span>
            <span style={styles.contextFlavor}>[{selectedNode.flavor}]</span>
            <button style={styles.contextClose} onClick={() => setSelectedNode(null)}>✕</button>
          </div>
          <div style={styles.contextId}>{selectedNode.id}</div>
          {onCopyContext && (
            <button
              style={styles.copyButton}
              onClick={() => {
                onCopyContext(selectedNode.id);
                setSelectedNode(null);
              }}
            >
              Copy Context for AI
            </button>
          )}
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  wrapper: {
    width: "100%",
    height: "100%",
    position: "relative",
  },
  container: {
    width: "100%",
    height: "100%",
    overflow: "hidden",
  },
  empty: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    height: "100%",
    opacity: 0.5,
  },
  contextPanel: {
    position: "absolute",
    bottom: 12,
    left: 12,
    right: 12,
    background: "var(--vscode-editor-background)",
    border: "1px solid var(--vscode-panel-border)",
    borderRadius: 6,
    padding: 12,
    zIndex: 10,
  },
  contextHeader: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    marginBottom: 4,
  },
  contextTitle: {
    fontWeight: 600,
    fontSize: "0.95em",
  },
  contextFlavor: {
    opacity: 0.5,
    fontSize: "0.8em",
  },
  contextClose: {
    marginLeft: "auto",
    background: "transparent",
    border: "none",
    color: "var(--vscode-foreground)",
    cursor: "pointer",
    fontSize: "1em",
    opacity: 0.5,
  },
  contextId: {
    fontSize: "0.75em",
    opacity: 0.4,
    marginBottom: 8,
    fontFamily: "var(--vscode-editor-font-family)",
  },
  copyButton: {
    width: "100%",
    background: "var(--vscode-button-background)",
    color: "var(--vscode-button-foreground)",
    border: "none",
    borderRadius: 4,
    padding: "8px 16px",
    cursor: "pointer",
    fontFamily: "var(--vscode-font-family)",
    fontSize: "var(--vscode-font-size)",
    fontWeight: 600,
  },
};
