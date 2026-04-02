import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";
import type { AnalysisResult, ProgressInfo } from "./protocol";
import type { FlatMapEntry } from "./analyzerBridge";

interface WebviewToHostMessage {
  type: "analyzeRequest" | "copyContext" | "openFile" | "requestRawJson" | "requestMembers" | "requestFilePreview" | "ready";
  filePath?: string;
  nodeId?: string;
  data?: { file: string; line: number; col: number };
}

export class ExplorerViewProvider implements vscode.WebviewViewProvider {
  public static readonly viewType = "swiftPrismExplorer";

  private view?: vscode.WebviewView;
  private onAnalyzeRequest?: () => void;
  private onCopyContext?: (nodeId: string) => void;
  private onOpenFile?: (data: { file: string; line: number; col: number }) => void;
  private onRequestRawJson?: () => void;
  private onRequestMembers?: (nodeId: string) => void;
  private onRequestFilePreview?: (nodeId: string, filePath: string) => void;

  constructor(private readonly extensionUri: vscode.Uri) {}

  setAnalyzeHandler(handler: () => void): void {
    this.onAnalyzeRequest = handler;
  }

  setCopyContextHandler(handler: (nodeId: string) => void): void {
    this.onCopyContext = handler;
  }

  setOpenFileHandler(handler: (data: { file: string; line: number; col: number }) => void): void {
    this.onOpenFile = handler;
  }

  setRequestRawJsonHandler(handler: () => void): void {
    this.onRequestRawJson = handler;
  }

  setRequestMembersHandler(handler: (nodeId: string) => void): void {
    this.onRequestMembers = handler;
  }

  setRequestFilePreviewHandler(handler: (nodeId: string, filePath: string) => void): void {
    this.onRequestFilePreview = handler;
  }

  resolveWebviewView(
    webviewView: vscode.WebviewView,
    _context: vscode.WebviewViewResolveContext,
    _token: vscode.CancellationToken
  ): void {
    this.view = webviewView;

    webviewView.webview.options = {
      enableScripts: true,
      localResourceRoots: [
        vscode.Uri.joinPath(this.extensionUri, "dist-webview"),
      ],
    };

    webviewView.webview.onDidReceiveMessage((msg: WebviewToHostMessage) => {
      if (msg.type === "analyzeRequest" && this.onAnalyzeRequest) {
        this.onAnalyzeRequest();
      }
      if (msg.type === "copyContext" && msg.nodeId && this.onCopyContext) {
        this.onCopyContext(msg.nodeId);
      }
      if (msg.type === "openFile" && msg.data && this.onOpenFile) {
        this.onOpenFile(msg.data);
      }
      if (msg.type === "requestRawJson" && this.onRequestRawJson) {
        this.onRequestRawJson();
      }
      if (msg.type === "requestMembers" && msg.nodeId && this.onRequestMembers) {
        this.onRequestMembers(msg.nodeId);
      }
      if (msg.type === "requestFilePreview" && msg.nodeId && msg.filePath && this.onRequestFilePreview) {
        this.onRequestFilePreview(msg.nodeId, msg.filePath);
      }
    });

    webviewView.webview.html = this.buildHtml(webviewView.webview);
  }

  sendProgress(progress: ProgressInfo): void {
    this.view?.webview.postMessage({ type: "progress", progress });
  }

  sendResult(result: AnalysisResult): void {
    this.view?.webview.postMessage({ type: "analysisResult", payload: result });
  }

  sendError(message: string): void {
    this.view?.webview.postMessage({ type: "error", message });
  }

  sendMappingData(entries: FlatMapEntry[]): void {
    this.view?.webview.postMessage({ type: "mappingData", payload: entries });
  }

  sendMemberDetail(parentId: string, result: AnalysisResult): void {
    this.view?.webview.postMessage({ type: "memberDetail", parentId, payload: result });
  }

  sendFilePreview(preview: { nodeId: string; previewType: string; data: string; fileName: string }): void {
    this.view?.webview.postMessage({ type: "filePreview", payload: preview });
  }

  sendContextCopied(tokenEstimate: number): void {
    this.view?.webview.postMessage({ type: "contextCopied", tokenEstimate });
  }

  private buildHtml(webview: vscode.Webview): string {
    const distPath = path.join(this.extensionUri.fsPath, "dist-webview");
    const jsFile = this.findAsset(distPath, ".js");
    const cssFile = this.findAsset(distPath, ".css");
    const jsUri = jsFile ? webview.asWebviewUri(vscode.Uri.file(jsFile)) : null;
    const cssUri = cssFile ? webview.asWebviewUri(vscode.Uri.file(cssFile)) : null;
    const nonce = this.generateNonce();
    const cssTag = cssUri ? `<link rel="stylesheet" href="${cssUri}">` : "";

    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}'; img-src ${webview.cspSource};">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body, #root { width: 100%; height: 100%; overflow: hidden; }
  </style>
  ${cssTag}
</head>
<body>
  <div id="root"></div>
  ${jsUri ? `<script nonce="${nonce}" src="${jsUri}"></script>` : `<p>Webview not built. Run: cd extension/webview && npm run build</p>`}
</body>
</html>`;
  }

  private findAsset(dir: string, ext: string): string | null {
    try {
      const files = fs.readdirSync(dir);
      const match = files.find((f) => f.endsWith(ext));
      return match ? path.join(dir, match) : null;
    } catch {
      return null;
    }
  }

  private generateNonce(): string {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let result = "";
    for (let i = 0; i < 32; i++) {
      result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
  }
}
