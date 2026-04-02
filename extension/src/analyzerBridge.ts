import { spawn, execFile, type ChildProcess } from "child_process";
import * as path from "path";
import * as fs from "fs";
import type { AnalysisResult, ProgressInfo } from "./protocol";

export class AnalyzerError extends Error {
  public readonly stderr: string;
  constructor(message: string, stderr: string = "") {
    super(message);
    this.name = "AnalyzerError";
    this.stderr = stderr;
  }
}

export interface AnalyzerCallbacks {
  onProgress: (progress: ProgressInfo) => void;
  onWarning: (message: string) => void;
}

export interface FlatMapEntry {
  id: string;
  name: string;
  type: string;
  location: { file: string; line: number; col: number };
  connections: string[];
}

export function resolveAnalyzerBinary(extensionPath: string): string {
  return path.join(extensionPath, "bin", "swift-prism-analyzer");
}

export function runSwiftAnalyzerToPath(
  binaryPath: string,
  projectPath: string,
  outputPath: string
): Promise<FlatMapEntry[]> {
  const outputDir = path.dirname(outputPath);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  return new Promise((resolve, reject) => {
    execFile(
      binaryPath,
      [projectPath, outputPath],
      { timeout: 300_000, maxBuffer: 50 * 1024 * 1024 },
      (error, _stdout, stderr) => {
        if (error) {
          const parsed = extractErrorMessage(stderr) || error.message;
          reject(new AnalyzerError(`Analyzer failed: ${parsed}`, stderr));
          return;
        }

        if (!fs.existsSync(outputPath)) {
          reject(new AnalyzerError(`Analyzer completed but output file not found: ${outputPath}`, stderr));
          return;
        }

        let raw: string;
        try {
          raw = fs.readFileSync(outputPath, "utf-8");
        } catch (readErr) {
          reject(new AnalyzerError(`Cannot read output file: ${readErr}`, stderr));
          return;
        }

        if (!raw.trim()) {
          reject(new AnalyzerError("Analyzer produced an empty output file", stderr));
          return;
        }

        try {
          const entries: FlatMapEntry[] = JSON.parse(raw);
          if (!Array.isArray(entries)) {
            reject(new AnalyzerError("Analyzer output is valid JSON but not an array", stderr));
            return;
          }
          resolve(entries);
        } catch {
          reject(new AnalyzerError(`Invalid JSON in output file. Preview: ${raw.slice(0, 200)}`, stderr));
        }
      }
    );
  });
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
      reject(new AnalyzerError(`Failed to launch analyzer: ${err.message}`, stderrText));
    });

    child.on("close", (code) => {
      if (code !== 0) {
        const parsed = extractErrorMessage(stderrText);
        reject(new AnalyzerError(parsed || `Analyzer exited with code ${code}`, stderrText));
        return;
      }
      const output = Buffer.concat(stdoutBuffers).toString("utf-8");
      if (!output.trim()) {
        reject(new AnalyzerError("Analyzer returned empty output", stderrText));
        return;
      }
      try {
        resolve(JSON.parse(output));
      } catch {
        const preview = output.slice(0, 200);
        reject(new AnalyzerError(`Invalid JSON from analyzer. Preview: ${preview}`, stderrText));
      }
    });
  });

  return { promise, process: child };
}

export function runSummaryAnalysis(
  binaryPath: string,
  args: string[],
  callbacks: AnalyzerCallbacks
): { promise: Promise<AnalysisResult>; process: ChildProcess } {
  return runAnalyzer(binaryPath, [...args, "--summary-only"], callbacks);
}

export function runMembersOf(
  binaryPath: string,
  parentId: string,
  args: string[]
): Promise<AnalysisResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, [...args, "--members-of", parentId], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const buffers: Buffer[] = [];
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => buffers.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.on("error", (err) => reject(new AnalyzerError(err.message, stderr)));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new AnalyzerError(extractErrorMessage(stderr) || `Members query failed (code ${code})`, stderr));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(buffers).toString("utf-8")));
      } catch {
        reject(new AnalyzerError("Failed to parse members JSON", stderr));
      }
    });
  });
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
    child.on("error", (err) => reject(new AnalyzerError(err.message, stderr)));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new AnalyzerError(extractErrorMessage(stderr) || `Context generation failed (code ${code})`, stderr));
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
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => buffers.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.on("error", (err) => reject(new AnalyzerError(err.message, stderr)));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new AnalyzerError(extractErrorMessage(stderr) || `Find dependents failed (code ${code})`, stderr));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(buffers).toString("utf-8")));
      } catch {
        reject(new AnalyzerError("Failed to parse dependents JSON", stderr));
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
