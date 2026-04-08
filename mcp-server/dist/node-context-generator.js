/**
 * node-context-generator.ts — Local LLM Pre-Processing Pipeline
 *
 * Generates token-optimized `node_context` strings for each important node
 * by sending source code to a local LLM (Ollama). Uses incremental caching
 * based on file content hashes to avoid redundant regeneration.
 *
 * Usage:
 *   npx ts-node node-context-generator.ts <graph-path> [--ollama-model codellama]
 *   node dist/node-context-generator.js <graph-path>
 */
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
const DEFAULT_CONFIG = {
    ollamaEndpoint: process.env.OLLAMA_ENDPOINT ?? "http://localhost:11434",
    ollamaModel: process.env.OLLAMA_MODEL ?? "codellama",
    maxConcurrent: 2,
    timeoutMs: 30_000,
    eligibleFlavors: new Set(["function", "class", "struct", "enum", "actor", "protocol", "macro", "entry_point"]),
};
const LLM_PROMPT = `Analyze this Swift code. Summarize its intent, side-effects, and dependencies into a dense, token-optimized string. Use symbolic notation or shorthand instead of natural language to minimize tokens while retaining maximum semantic meaning for another LLM.

Rules:
- Use arrows (→) for returns/output, (←) for inputs/dependencies
- Use @ for side-effects (e.g. @disk, @net, @state, @ui)
- Use :: for type relationships
- Use [] for collections, ? for optionals
- Compress common patterns: init→, deinit→, async→, throws→
- Max 200 chars

Code:
`;
// ═══════════════════════════════════════════════════════════════════════════════
// FILE HASH — Incremental cache key
// ═══════════════════════════════════════════════════════════════════════════════
function hashFile(filePath) {
    try {
        const content = fs.readFileSync(filePath, "utf-8");
        return crypto.createHash("sha256").update(content).digest("hex").slice(0, 16);
    }
    catch {
        return null;
    }
}
// ═══════════════════════════════════════════════════════════════════════════════
// SOURCE EXTRACTION — Read node's source code from disk
// ═══════════════════════════════════════════════════════════════════════════════
function extractSourceCode(node, maxLines = 80) {
    const filePath = node.location?.absPath;
    const startLine = node.location?.line;
    if (!filePath || !startLine || !fs.existsSync(filePath))
        return null;
    try {
        const lines = fs.readFileSync(filePath, "utf-8").split("\n");
        const start = Math.max(0, startLine - 1);
        // Heuristic: read until matching brace depth returns to 0 or maxLines
        let depth = 0;
        let foundOpen = false;
        let end = start;
        for (let i = start; i < Math.min(lines.length, start + maxLines); i++) {
            const line = lines[i];
            for (const ch of line) {
                if (ch === "{") {
                    depth++;
                    foundOpen = true;
                }
                if (ch === "}")
                    depth--;
            }
            end = i;
            if (foundOpen && depth <= 0)
                break;
        }
        return lines.slice(start, end + 1).join("\n");
    }
    catch {
        return null;
    }
}
// ═══════════════════════════════════════════════════════════════════════════════
// OLLAMA CLIENT
// ═══════════════════════════════════════════════════════════════════════════════
async function queryOllama(sourceCode, config) {
    const body = JSON.stringify({
        model: config.ollamaModel,
        prompt: LLM_PROMPT + sourceCode,
        stream: false,
        options: {
            temperature: 0.1,
            num_predict: 256,
        },
    });
    try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), config.timeoutMs);
        const res = await fetch(`${config.ollamaEndpoint}/api/generate`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body,
            signal: controller.signal,
        });
        clearTimeout(timeout);
        if (!res.ok) {
            console.error(`[NodeContext] Ollama returned ${res.status}`);
            return null;
        }
        const json = await res.json();
        return json.response?.trim() ?? null;
    }
    catch (err) {
        if (err.name === "AbortError") {
            console.error(`[NodeContext] Ollama timed out after ${config.timeoutMs}ms`);
        }
        else {
            console.error(`[NodeContext] Ollama error: ${err.message}`);
        }
        return null;
    }
}
// ═══════════════════════════════════════════════════════════════════════════════
// FALLBACK — Deterministic summary when LLM is unavailable
// ═══════════════════════════════════════════════════════════════════════════════
function generateFallbackContext(node, sourceCode) {
    const parts = [];
    // Flavor shorthand
    const flavorMap = {
        function: "fn", class: "cls", struct: "str", enum: "enm",
        actor: "act", protocol: "proto", macro: "macro", entry_point: "entry",
    };
    parts.push(flavorMap[node.flavor] ?? node.flavor);
    parts.push(node.name);
    // Dependencies
    if (node.calls?.length)
        parts.push(`→[${node.calls.length}calls]`);
    if (node.inits?.length)
        parts.push(`init→[${node.inits.join(",")}]`);
    if (node.stores?.length)
        parts.push(`dep:[${node.stores.join(",")}]`);
    if (node.extends)
        parts.push(`ext:${node.extends}`);
    if (node.implements?.length)
        parts.push(`impl:[${node.implements.join(",")}]`);
    if (node.parameters?.length)
        parts.push(`←(${node.parameters.join(",")})`);
    if (node.returns?.length)
        parts.push(`→(${node.returns.join(",")})`);
    // Side-effect hints from source
    if (sourceCode) {
        const effects = [];
        if (/URLSession|fetch|request|download/i.test(sourceCode))
            effects.push("@net");
        if (/FileManager|write|read.*File|NSData/i.test(sourceCode))
            effects.push("@disk");
        if (/UserDefaults|CoreData|Realm|NSManagedObject/i.test(sourceCode))
            effects.push("@state");
        if (/UIView|UIViewController|SwiftUI|@Published|@State/i.test(sourceCode))
            effects.push("@ui");
        if (/DispatchQueue|Task\s*\{|async\s/i.test(sourceCode))
            effects.push("@async");
        if (/throw|throws/i.test(sourceCode))
            effects.push("@throws");
        if (/print\(|NSLog|os_log|Logger/i.test(sourceCode))
            effects.push("@log");
        if (effects.length)
            parts.push(effects.join(""));
    }
    return parts.join(" ");
}
// ═══════════════════════════════════════════════════════════════════════════════
// CACHE MANAGEMENT
// ═══════════════════════════════════════════════════════════════════════════════
function loadCache(cachePath) {
    if (!fs.existsSync(cachePath))
        return { version: "1.0", entries: {} };
    try {
        return JSON.parse(fs.readFileSync(cachePath, "utf-8"));
    }
    catch {
        return { version: "1.0", entries: {} };
    }
}
function saveCache(cachePath, cache) {
    fs.writeFileSync(cachePath, JSON.stringify(cache, null, 2));
}
/**
 * Generate node_context for all eligible nodes in the graph.
 * Writes enriched nodes back to the graph file with `node_context` field.
 * Uses incremental caching — only regenerates when source file hash changes.
 */
export async function generateNodeContexts(graphPath, outputDir, configOverrides = {}) {
    const config = { ...DEFAULT_CONFIG, ...configOverrides };
    const cachePath = path.join(outputDir, "node-context-cache.json");
    const cache = loadCache(cachePath);
    // Load graph nodes
    const raw = fs.readFileSync(graphPath, "utf-8");
    const parsed = JSON.parse(raw);
    const nodes = Array.isArray(parsed) ? parsed : parsed.nodes ?? [];
    // Filter eligible nodes
    const eligible = nodes.filter((n) => config.eligibleFlavors.has(n.flavor));
    const result = { total: eligible.length, generated: 0, cached: 0, failed: 0, usedLLM: false };
    // Check if Ollama is reachable
    let ollamaAvailable = false;
    try {
        const probe = await fetch(`${config.ollamaEndpoint}/api/tags`, { signal: AbortSignal.timeout(3000) });
        ollamaAvailable = probe.ok;
        if (ollamaAvailable) {
            result.usedLLM = true;
            console.error(`[NodeContext] Ollama available (model: ${config.ollamaModel})`);
        }
    }
    catch {
        console.error("[NodeContext] Ollama not reachable — using deterministic fallback");
    }
    // Process nodes
    const nodeMap = new Map(nodes.map((n) => [n.id, n]));
    for (const node of eligible) {
        const fileHash = hashFile(node.location.absPath);
        const cacheKey = node.id;
        // Check cache validity
        const cached = cache.entries[cacheKey];
        if (cached && fileHash && cached.fileHash === fileHash) {
            // Cache hit — file unchanged
            node.node_context = cached.nodeContext;
            result.cached++;
            continue;
        }
        // Extract source
        const sourceCode = extractSourceCode(node);
        let context = null;
        // Try LLM first
        if (ollamaAvailable && sourceCode) {
            context = await queryOllama(sourceCode, config);
        }
        // Fallback to deterministic
        if (!context) {
            context = generateFallbackContext(node, sourceCode);
        }
        node.node_context = context;
        // Update cache
        if (fileHash) {
            cache.entries[cacheKey] = {
                fileHash,
                nodeContext: context,
                generatedAt: new Date().toISOString(),
            };
        }
        result.generated++;
    }
    // Write enriched graph back
    const output = Array.isArray(parsed) ? nodes : { ...parsed, nodes };
    fs.writeFileSync(graphPath, JSON.stringify(output));
    // Save cache
    saveCache(cachePath, cache);
    console.error(`[NodeContext] Done: ${result.generated} generated, ${result.cached} cached, ${result.failed} failed` +
        ` (LLM: ${result.usedLLM ? "yes" : "fallback"})`);
    return result;
}
// ═══════════════════════════════════════════════════════════════════════════════
// STEALTH COMPRESSION — Token-saving shorthand for Swift terms
// ═══════════════════════════════════════════════════════════════════════════════
const STEALTH_COMPRESSION_MAP = [
    [/\bfunc\b/g, "f"],
    [/\bfunction\b/g, "f"],
    [/\bvariable\b/g, "v"],
    [/\breturn\b/g, "r"],
    [/\bstruct\b/g, "S"],
    [/\bclass\b/g, "C"],
    [/\benum\b/g, "E"],
    [/\bprotocol\b/g, "P"],
    [/\bextension\b/g, "X"],
    [/\bproperty\b/g, "p"],
    [/\boptional\b/g, "?"],
    [/\basync\b/g, "⚡"],
    [/\bawait\b/g, "⏳"],
    [/\bthrows\b/g, "⚠"],
    [/\bpublic\b/g, "+"],
    [/\bprivate\b/g, "-"],
    [/\binternal\b/g, "~"],
    [/\bstatic\b/g, "§"],
    [/\bmutating\b/g, "μ"],
    [/\boverride\b/g, "↑"],
    [/\binit\b/g, "⊕"],
    [/\bdeinit\b/g, "⊖"],
    [/\bString\b/g, "Str"],
    [/\bInt\b/g, "I"],
    [/\bBool\b/g, "B"],
    [/\bDouble\b/g, "D"],
    [/\bArray\b/g, "[]"],
    [/\bDictionary\b/g, "{}"],
    [/\bVoid\b/g, "∅"],
    [/\bnil\b/g, "∅"],
    [/\bself\b/g, "λ"],
    [/\bguard\b/g, "G"],
    [/\bimport\b/g, "⬇"],
];
/**
 * Apply stealth compression to a node_context string.
 * Replaces common Swift terms with compact symbols.
 */
export function applyStealthCompression(context) {
    let result = context;
    for (const [pattern, replacement] of STEALTH_COMPRESSION_MAP) {
        result = result.replace(pattern, replacement);
    }
    // Remove redundant whitespace
    return result.replace(/\s{2,}/g, " ").trim();
}
// ═══════════════════════════════════════════════════════════════════════════════
// CLI ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════════
if (process.argv[1]?.endsWith("node-context-generator.js") || process.argv[1]?.endsWith("node-context-generator.ts")) {
    const graphPath = process.argv[2];
    if (!graphPath) {
        console.error("Usage: node node-context-generator.js <graph-path> [--ollama-model <model>]");
        process.exit(1);
    }
    const modelIdx = process.argv.indexOf("--ollama-model");
    const model = modelIdx >= 0 ? process.argv[modelIdx + 1] : undefined;
    const outputDir = path.dirname(graphPath);
    generateNodeContexts(graphPath, outputDir, model ? { ollamaModel: model } : {})
        .then((r) => {
        console.log(JSON.stringify(r));
    })
        .catch((err) => {
        console.error("Generation failed:", err);
        process.exit(1);
    });
}
