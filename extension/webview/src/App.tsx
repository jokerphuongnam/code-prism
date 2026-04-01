import { useState, useCallback, useRef } from "react";
import type { AnalysisResult, HostToWebviewMessage, ProgressInfo } from "./protocol";
import { useVscodeMessaging, usePostMessage } from "./hooks/useVscodeMessaging";
import { Header } from "./components/Header";
import { GraphView } from "./components/GraphView";
import { JsonPreview } from "./components/JsonPreview";
import { GuideView } from "./components/GuideView";
import { StatusBar } from "./components/StatusBar";

export type ViewTab = "graph" | "json" | "guide";

const IDLE_PROGRESS: ProgressInfo = { phase: "idle", processed: 0, total: 0 };

export function App() {
  const [result, setResult] = useState<AnalysisResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState<ProgressInfo>(IDLE_PROGRESS);
  const [activeTab, setActiveTab] = useState<ViewTab>("graph");
  const [highlightedIds, setHighlightedIds] = useState<Set<string>>(new Set());
  const [contextToast, setContextToast] = useState<string | null>(null);
  const postMessage = usePostMessage();

  const lkgResult = useRef<AnalysisResult | null>(null);

  const handleMessage = useCallback((msg: HostToWebviewMessage) => {
    switch (msg.type) {
      case "analysisResult":
        lkgResult.current = msg.payload;
        setResult(msg.payload);
        setError(null);
        setProgress({ phase: "complete", processed: 1, total: 1 });
        break;
      case "progress":
        setProgress(msg.progress);
        setError(null);
        break;
      case "error":
        setProgress({ phase: "error", processed: 0, total: 0 });
        setError(msg.message);
        if (lkgResult.current) {
          setResult(lkgResult.current);
        }
        break;
      case "contextCopied":
        setContextToast(`Context copied (~${msg.tokenEstimate} tokens)`);
        setTimeout(() => setContextToast(null), 3000);
        break;
    }
  }, []);

  useVscodeMessaging(handleMessage);

  const handleAnalyze = useCallback(() => {
    postMessage({ type: "analyzeRequest" });
  }, [postMessage]);

  const handleCopyContext = useCallback((nodeId: string) => {
    postMessage({ type: "copyContext", nodeId });
  }, [postMessage]);

  const handleGuideHighlight = useCallback((ids: Set<string>) => {
    setHighlightedIds(ids);
    if (ids.size > 0 && activeTab === "guide") {
      setActiveTab("graph");
    }
  }, [activeTab]);

  const isAnalyzing =
    progress.phase !== "idle" &&
    progress.phase !== "complete" &&
    progress.phase !== "error";

  const displayResult = result;
  const isLkg = error !== null && displayResult !== null;
  const hasResources = (displayResult?.resources?.length ?? 0) > 0;

  return (
    <div style={styles.root}>
      <Header
        result={displayResult}
        loading={isAnalyzing}
        onAnalyze={handleAnalyze}
        activeTab={activeTab}
        onTabChange={setActiveTab}
        isLkg={isLkg}
        hasResources={hasResources}
      />
      {error && <div style={styles.error}>{error}</div>}
      {contextToast && <div style={styles.toast}>{contextToast}</div>}
      <main style={styles.main}>
        {activeTab === "graph" && (
          <GraphView
            result={displayResult}
            highlightedIds={highlightedIds}
            onCopyContext={handleCopyContext}
          />
        )}
        {activeTab === "json" && <JsonPreview result={displayResult} />}
        {activeTab === "guide" && (
          <GuideView
            result={displayResult}
            onHighlight={handleGuideHighlight}
            onCopyContext={handleCopyContext}
          />
        )}
      </main>
      <StatusBar progress={progress} />
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  root: {
    display: "flex",
    flexDirection: "column",
    height: "100vh",
    width: "100vw",
    overflow: "hidden",
    fontFamily: "var(--vscode-font-family)",
    color: "var(--vscode-foreground)",
    background: "var(--vscode-sideBar-background)",
  },
  error: {
    color: "var(--vscode-errorForeground)",
    background: "var(--vscode-inputValidation-errorBackground)",
    border: "1px solid var(--vscode-inputValidation-errorBorder)",
    borderRadius: 4,
    padding: "8px 12px",
    margin: "8px 12px 0",
    fontSize: "0.9em",
  },
  toast: {
    background: "var(--vscode-badge-background)",
    color: "var(--vscode-badge-foreground)",
    borderRadius: 4,
    padding: "6px 12px",
    margin: "8px 12px 0",
    fontSize: "0.85em",
    textAlign: "center" as const,
  },
  main: {
    flex: 1,
    overflow: "hidden",
    position: "relative",
  },
};
