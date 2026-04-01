import { spawn, type ChildProcess } from "child_process";
import * as path from "path";
import type { AnalysisResult, ProgressInfo } from "./protocol";

export class AnalyzerError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AnalyzerError";
  }
}

export interface AnalyzerCallbacks {
  onProgress: (progress: ProgressInfo) => void;
  onWarning: (message: string) => void;
}

export function resolveAnalyzerBinary(extensionPath: string): string {
  return path.join(extensionPath, "bin", "swift-prism-analyzer");
}

export function runAnalyzer(
  binaryPath: string,
  args: string[],
  callbacks: AnalyzerCallbacks
): { promise: Promise<AnalysisResult>; process: ChildProcess } {
  const child = spawn(binaryPath, args, {
    stdio: ["ignore", "pipe", "pipe"],
  });

  const stdoutBuffers: Buffer[] = [];
  let stderrText = "";

  child.stdout.on("data", (chunk: Buffer) => {
    stdoutBuffers.push(chunk);
    callbacks.onProgress({ phase: "streaming", processed: 0, total: 0 });
  });

  child.stderr.on("data", (chunk: Buffer) => {
    const text = chunk.toString();
    stderrText += text;
    parseStderrLines(text, callbacks);
  });

  const promise = new Promise<AnalysisResult>((resolve, reject) => {
    child.on("error", (err) => {
      reject(new AnalyzerError(`Failed to launch analyzer: ${err.message}`));
    });

    child.on("close", (code) => {
      if (code !== 0) {
        reject(new AnalyzerError(extractErrorMessage(stderrText) || `Analyzer exited with code ${code}`));
        return;
      }
      const output = Buffer.concat(stdoutBuffers).toString("utf-8");
      if (!output.trim()) {
        reject(new AnalyzerError("Analyzer returned empty output"));
        return;
      }
      try {
        resolve(JSON.parse(output));
      } catch {
        reject(new AnalyzerError("Failed to parse analyzer JSON output"));
      }
    });
  });

  return { promise, process: child };
}

export async function runContextGenerator(
  binaryPath: string,
  workspacePath: string,
  swiftFiles: string[],
  outputPath: string
): Promise<void> {
  return new Promise((resolve, reject) => {
    const args = ["--workspace", workspacePath, "--context", "--output", outputPath, ...swiftFiles];
    const child = spawn(binaryPath, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.on("error", (err) => reject(new AnalyzerError(err.message)));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new AnalyzerError(extractErrorMessage(stderr) || `Context generation failed (code ${code})`));
      } else {
        resolve();
      }
    });
  });
}

export async function runFindDependents(
  binaryPath: string,
  workspacePath: string,
  swiftFiles: string[],
  targetId: string
): Promise<Record<string, string[]>> {
  return new Promise((resolve, reject) => {
    const args = ["--workspace", workspacePath, "--find-dependents-of", targetId, ...swiftFiles];
    const child = spawn(binaryPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    const buffers: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => buffers.push(chunk));
    let stderr = "";
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.on("error", (err) => reject(new AnalyzerError(err.message)));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new AnalyzerError(extractErrorMessage(stderr) || `Find dependents failed (code ${code})`));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(buffers).toString("utf-8")));
      } catch {
        reject(new AnalyzerError("Failed to parse dependents JSON"));
      }
    });
  });
}

function parseStderrLines(text: string, callbacks: AnalyzerCallbacks) {
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const msg = JSON.parse(trimmed);
      if (msg._progress) callbacks.onProgress(msg._progress as ProgressInfo);
      else if (msg._warning) callbacks.onWarning(msg._warning);
    } catch { /* skip */ }
  }
}

function extractErrorMessage(stderr: string): string | null {
  for (const line of stderr.split("\n").reverse()) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const msg = JSON.parse(trimmed);
      if (msg._error) return String(msg._error);
    } catch { /* skip */ }
  }
  return null;
}
