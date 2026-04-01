import * as vscode from "vscode";
import * as path from "path";
import type { ChildProcess } from "child_process";
import { ExplorerViewProvider } from "./explorerViewProvider";
import { resolveAnalyzerBinary, runAnalyzer, runContextGenerator, runFindDependents, AnalyzerError } from "./analyzerBridge";
import { findSwiftFiles, getWorkspaceRoot } from "./swiftFileDiscovery";

let activeProcess: ChildProcess | null = null;

export function activate(context: vscode.ExtensionContext) {
  const viewProvider = new ExplorerViewProvider(context.extensionUri);

  const runAnalysis = async () => {
    if (activeProcess) {
      activeProcess.kill();
      activeProcess = null;
    }

    const workspaceRoot = getWorkspaceRoot();
    if (!workspaceRoot) {
      vscode.window.showErrorMessage("SwiftPrism: Open a workspace folder first.");
      return;
    }

    viewProvider.sendProgress({ phase: "scanning", processed: 0, total: 0 });

    try {
      const swiftFiles = await findSwiftFiles(workspaceRoot);

      if (swiftFiles.length === 0) {
        viewProvider.sendError("No .swift files found in workspace.");
        return;
      }

      const binaryPath = resolveAnalyzerBinary(context.extensionPath);
      const workspacePath = workspaceRoot.fsPath;

      const { promise, process } = runAnalyzer(
        binaryPath,
        ["--workspace", workspacePath, "--scan-targets", "--public-only-external", ...swiftFiles],
        {
          onProgress: (progress) => viewProvider.sendProgress(progress),
          onWarning: (message) => vscode.window.showWarningMessage(`SwiftPrism: ${message}`),
        }
      );

      activeProcess = process;
      const result = await promise;
      activeProcess = null;

      viewProvider.sendResult(result);

      const contextPath = path.join(workspacePath, "prism-context.json");
      generateContextFile(binaryPath, workspacePath, swiftFiles, contextPath);

      const resourceCount = result.resources?.length ?? 0;
      const resourceMsg = resourceCount > 0 ? `, ${resourceCount} resources` : "";
      vscode.window.showInformationMessage(
        `SwiftPrism: ${result.nodes.length} symbols, ${result.links.length} links${resourceMsg}.`
      );
    } catch (err) {
      activeProcess = null;
      const message = err instanceof AnalyzerError ? err.message : "Unexpected error during analysis.";
      viewProvider.sendError(message);
      vscode.window.showErrorMessage(`SwiftPrism: ${message}`);
    }
  };

  const handleCopyContext = async (nodeId: string) => {
    const workspaceRoot = getWorkspaceRoot();
    if (!workspaceRoot) return;

    try {
      const binaryPath = resolveAnalyzerBinary(context.extensionPath);
      const swiftFiles = await findSwiftFiles(workspaceRoot);
      const workspacePath = workspaceRoot.fsPath;
      const dependents = await runFindDependents(binaryPath, workspacePath, swiftFiles, nodeId);
      const prompt = buildContextPrompt(nodeId, dependents);
      await vscode.env.clipboard.writeText(prompt);
      const tokenEstimate = Math.ceil(prompt.length / 4);
      viewProvider.sendContextCopied(tokenEstimate);
      vscode.window.showInformationMessage(`SwiftPrism: Context copied (~${tokenEstimate} tokens).`);
    } catch (err) {
      const message = err instanceof AnalyzerError ? err.message : "Failed to generate context.";
      vscode.window.showErrorMessage(`SwiftPrism: ${message}`);
    }
  };

  viewProvider.setAnalyzeHandler(runAnalysis);
  viewProvider.setCopyContextHandler(handleCopyContext);

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(ExplorerViewProvider.viewType, viewProvider)
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("swiftPrism.analyzeProject", runAnalysis)
  );

  context.subscriptions.push({
    dispose: () => {
      activeProcess?.kill();
      activeProcess = null;
    },
  });
}

function generateContextFile(binaryPath: string, workspacePath: string, swiftFiles: string[], outputPath: string) {
  runContextGenerator(binaryPath, workspacePath, swiftFiles, outputPath).catch(() => {});
}

function buildContextPrompt(nodeId: string, dependents: Record<string, string[]>): string {
  const lines: string[] = [];
  lines.push(`# SwiftPrism Context: ${nodeId}`);
  lines.push("");

  if (dependents.files?.length) {
    lines.push("## Related Files");
    for (const f of dependents.files) {
      lines.push(`- ${f}`);
    }
    lines.push("");
  }

  if (dependents.direct?.length) {
    lines.push("## Direct Dependencies");
    for (const d of dependents.direct) {
      lines.push(`- ${d}`);
    }
    lines.push("");
  }

  if (dependents.transitive?.length) {
    lines.push("## Transitive Dependencies (depth 3)");
    for (const t of dependents.transitive) {
      lines.push(`- ${t}`);
    }
    lines.push("");
  }

  if (dependents.resources?.length) {
    lines.push("## Resources");
    for (const r of dependents.resources) {
      lines.push(`- ${r}`);
    }
    lines.push("");
  }

  lines.push("---");
  lines.push(`> Generated by SwiftPrism. Query: \`swift-prism-analyzer --find-dependents-of "${nodeId}"\``);

  return lines.join("\n");
}

export function deactivate() {
  activeProcess?.kill();
  activeProcess = null;
}
