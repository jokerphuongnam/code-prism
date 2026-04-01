import type { AnalysisResult } from "../protocol";
import type { ViewTab } from "../App";

interface HeaderProps {
  result: AnalysisResult | null;
  loading: boolean;
  onAnalyze: () => void;
  activeTab: ViewTab;
  onTabChange: (tab: ViewTab) => void;
  isLkg: boolean;
  hasResources: boolean;
}

export function Header({
  result,
  loading,
  onAnalyze,
  activeTab,
  onTabChange,
  isLkg,
  hasResources,
}: HeaderProps) {
  const resourceCount = result?.resources?.length ?? 0;

  return (
    <header style={styles.header}>
      <div style={styles.left}>
        <button
          style={styles.analyzeButton}
          onClick={onAnalyze}
          disabled={loading}
        >
          {loading ? "Analyzing…" : "▶ Analyze Project"}
        </button>
        {result && (
          <span style={styles.stats}>
            {result.nodes.length} symbols · {result.links.length} links
            {resourceCount > 0 && ` · ${resourceCount} resources`}
            {isLkg && <span style={styles.lkg}> (cached)</span>}
          </span>
        )}
      </div>
      <div style={styles.tabs}>
        <button
          style={activeTab === "graph" ? styles.activeTab : styles.tab}
          onClick={() => onTabChange("graph")}
        >
          3D Graph
        </button>
        <button
          style={activeTab === "json" ? styles.activeTab : styles.tab}
          onClick={() => onTabChange("json")}
        >
          JSON
        </button>
        {hasResources && (
          <button
            style={activeTab === "guide" ? styles.activeTab : styles.tab}
            onClick={() => onTabChange("guide")}
          >
            Guide
          </button>
        )}
      </div>
    </header>
  );
}

const styles: Record<string, React.CSSProperties> = {
  header: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    padding: "8px 12px",
    borderBottom: "1px solid var(--vscode-panel-border)",
    flexShrink: 0,
  },
  left: {
    display: "flex",
    alignItems: "center",
    gap: 12,
  },
  analyzeButton: {
    background: "var(--vscode-button-background)",
    color: "var(--vscode-button-foreground)",
    border: "none",
    borderRadius: 4,
    padding: "6px 14px",
    cursor: "pointer",
    fontFamily: "var(--vscode-font-family)",
    fontSize: "var(--vscode-font-size)",
    fontWeight: 600,
  },
  stats: {
    opacity: 0.7,
    fontSize: "0.9em",
  },
  lkg: {
    color: "var(--vscode-editorWarning-foreground, #FFD54F)",
    fontStyle: "italic",
  },
  tabs: {
    display: "flex",
    gap: 4,
  },
  tab: {
    background: "transparent",
    color: "var(--vscode-foreground)",
    border: "1px solid var(--vscode-panel-border)",
    borderRadius: 4,
    padding: "4px 10px",
    cursor: "pointer",
    fontFamily: "var(--vscode-font-family)",
    fontSize: "0.85em",
    opacity: 0.6,
  },
  activeTab: {
    background: "var(--vscode-badge-background)",
    color: "var(--vscode-badge-foreground)",
    border: "1px solid transparent",
    borderRadius: 4,
    padding: "4px 10px",
    cursor: "pointer",
    fontFamily: "var(--vscode-font-family)",
    fontSize: "0.85em",
    opacity: 1,
  },
};
