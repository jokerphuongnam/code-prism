#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as fs from "fs";
import * as path from "path";
import { FragmentLoader, fragmentGraph } from "./fragment-store.js";
import { applyStealthCompression } from "./node-context-generator.js";
// ═══════════════════════════════════════════════════════════════════════════════
// PROJECT DISCOVERY — Hidden Data Resolution
//
// 1. Walk upward from CWD to find the Project Anchor (.git, Package.swift, .xcodeproj)
// 2. Resolve hidden data at <anchor>/.swiftprism/swiftprism-config.json
// 3. Fall back to visible swiftprism-config.json at anchor root (legacy)
// 4. Fall back to prism-context.json at anchor root (pre-config era)
// ═══════════════════════════════════════════════════════════════════════════════
const PROJECT_ANCHORS = [".git", "Package.swift"];
const HIDDEN_DIR = ".swiftprism";
const HIDDEN_CONFIG = "swiftprism-config.json";
const STEALTH_MODE = process.env.SWIFTPRISM_MODE === "stealth";
const STEALTH_COMPRESSION = process.env.SWIFTPRISM_COMPRESS === "1";
// ── Project Anchor Discovery ──
// Walk upward from startDir to find the nearest directory containing
// .git, Package.swift, or *.xcodeproj. Returns the anchor directory.
function findProjectRoot(startDir) {
    let dir = startDir;
    while (true) {
        for (const anchor of PROJECT_ANCHORS) {
            if (fs.existsSync(path.join(dir, anchor)))
                return dir;
        }
        try {
            if (fs.readdirSync(dir).some((e) => e.endsWith(".xcodeproj")))
                return dir;
        }
        catch { /* unreadable — skip */ }
        const parent = path.dirname(dir);
        if (parent === dir)
            break;
        dir = parent;
    }
    return null;
}
// ── Config Loader ──
// Reads swiftprism-config.json, resolves relative paths against baseDir,
// and verifies the graph file exists on disk.
function tryLoadConfig(configPath, baseDir, projectRoot) {
    if (!fs.existsSync(configPath))
        return null;
    try {
        const cfg = JSON.parse(fs.readFileSync(configPath, "utf-8"));
        const resolvedGraph = cfg.graphPath
            ? (path.isAbsolute(cfg.graphPath) ? cfg.graphPath : path.resolve(baseDir, cfg.graphPath))
            : null;
        if (!resolvedGraph || !fs.existsSync(resolvedGraph))
            return null;
        return {
            graphPath: resolvedGraph,
            contextsDir: cfg.contextsDir
                ? (path.isAbsolute(cfg.contextsDir) ? cfg.contextsDir : path.resolve(baseDir, cfg.contextsDir))
                : path.join(path.dirname(resolvedGraph), "contexts"),
            projectRoot,
        };
    }
    catch {
        return null;
    }
}
// ── Path Resolution ──
// Priority order:
//   1. <anchor>/.swiftprism/swiftprism-config.json  (hidden / stealth)
//   2. <anchor>/swiftprism-config.json              (visible — skipped in stealth mode)
//   3. <anchor>/prism-context.json                  (legacy — skipped in stealth mode)
//   4. Walk upward from CWD checking each dir       (fallback if no anchor found)
function resolveProjectPaths() {
    const cwd = process.cwd();
    const anchor = findProjectRoot(cwd);
    if (anchor) {
        // Priority 1: Hidden config
        const hiddenDir = path.join(anchor, HIDDEN_DIR);
        const hidden = tryLoadConfig(path.join(hiddenDir, HIDDEN_CONFIG), hiddenDir, anchor);
        if (hidden)
            return hidden;
        if (!STEALTH_MODE) {
            // Priority 2: Visible config at anchor root
            const visible = tryLoadConfig(path.join(anchor, HIDDEN_CONFIG), anchor, anchor);
            if (visible)
                return visible;
            // Priority 3: Legacy prism-context.json
            const legacyPath = path.join(anchor, "prism-context.json");
            if (fs.existsSync(legacyPath)) {
                return { graphPath: legacyPath, contextsDir: path.join(anchor, "out", "contexts"), projectRoot: anchor };
            }
        }
    }
    // Fallback: walk upward from CWD checking every directory
    let dir = cwd;
    while (true) {
        const hiddenDir = path.join(dir, HIDDEN_DIR);
        const hidden = tryLoadConfig(path.join(hiddenDir, HIDDEN_CONFIG), hiddenDir, dir);
        if (hidden)
            return hidden;
        if (!STEALTH_MODE) {
            const visible = tryLoadConfig(path.join(dir, HIDDEN_CONFIG), dir, dir);
            if (visible)
                return visible;
        }
        const parent = path.dirname(dir);
        if (parent === dir)
            break;
        dir = parent;
    }
    return null;
}
const NOT_CONFIGURED_MSG = "Graph data not found. Please run ./run.sh in your project root to initialize the " +
    (STEALTH_MODE ? "stealth context." : "graph data.");
function notConfiguredResponse() {
    return { content: [{ type: "text", text: NOT_CONFIGURED_MSG }] };
}
// ═══════════════════════════════════════════════════════════════════════════════
// DATA ACCESS — Fragment-first, monolithic fallback
//
// When fragments exist (.swiftprism/graph-index.json), nodes are loaded
// on-demand from small per-object files. Nothing persists in memory.
// When only a monolithic graph exists, it's loaded per-request then freed.
// ═══════════════════════════════════════════════════════════════════════════════
function getFragmentLoader() {
    const paths = resolveProjectPaths();
    if (!paths)
        return null;
    const loader = new FragmentLoader(path.dirname(paths.graphPath));
    return loader.available ? loader : null;
}
function loadGraph() {
    const paths = resolveProjectPaths();
    if (!paths)
        return null;
    try {
        const raw = fs.readFileSync(paths.graphPath, "utf-8");
        const parsed = JSON.parse(raw);
        // Handle both formats: raw array or {nodes, targets} object
        if (Array.isArray(parsed))
            return { nodes: parsed };
        return parsed;
    }
    catch {
        return null;
    }
}
/** Auto-fragment the monolithic graph if fragments don't exist yet */
function ensureFragments() {
    const paths = resolveProjectPaths();
    if (!paths)
        return null;
    const stealthDir = path.dirname(paths.graphPath);
    const loader = new FragmentLoader(stealthDir);
    if (loader.available)
        return loader;
    // Auto-fragment from monolithic graph
    if (fs.existsSync(paths.graphPath)) {
        try {
            console.error("[SwiftPrism MCP] Auto-fragmenting graph for on-demand loading...");
            fragmentGraph(paths.graphPath, stealthDir);
            console.error("[SwiftPrism MCP] Fragmentation complete.");
            loader.invalidate();
            return loader.available ? loader : null;
        }
        catch (err) {
            console.error("[SwiftPrism MCP] Fragmentation failed (non-fatal):", err);
        }
    }
    return null;
}
function findNode(id) {
    // Try fragment loader first (single file read)
    const loader = getFragmentLoader();
    if (loader) {
        const node = loader.loadNode(id);
        return node ?? undefined;
    }
    // Fallback: monolithic
    return loadGraph()?.nodes.find((n) => n.id === id);
}
// ═══════════════════════════════════════════════════════════════════════════════
// TOKEN-OPTIMIZED OUTPUT — Prefer node_context over full node data
//
// When node_context is present, return a compact representation.
// If stealth compression is active, further shorten Swift terms.
// Full source is only sent when explicitly requested (full_source=true).
// ═══════════════════════════════════════════════════════════════════════════════
function toTokenOptimized(node, fullSource = false) {
    if (fullSource || !node.node_context) {
        // No pre-digested context or full source requested — return everything
        return node;
    }
    // Return compact representation with pre-digested context
    const context = STEALTH_COMPRESSION
        ? applyStealthCompression(node.node_context)
        : node.node_context;
    return {
        id: node.id,
        name: node.name,
        flavor: node.flavor,
        node_context: context,
        location: node.location,
        parents: node.parents,
        // Keep relationship IDs for graph traversal
        ...(node.calls?.length ? { calls: node.calls } : {}),
        ...(node.inits?.length ? { inits: node.inits } : {}),
        ...(node.stores?.length ? { stores: node.stores } : {}),
    };
}
function toTokenOptimizedFragment(id, nodeById, fullSource = false) {
    const node = nodeById.get(id);
    if (!node)
        return { id, name: id, flavor: "unknown" };
    return toTokenOptimized(node, fullSource);
}
function findCallers(targetId) {
    const loader = getFragmentLoader();
    if (loader) {
        // Scan fragments one at a time — each is freed after processing
        const callers = [];
        loader.forEachFragment((nodes) => {
            for (const n of nodes) {
                if (n.calls?.includes(targetId) || n.inits?.includes(targetId) || n.deinits?.includes(targetId)) {
                    callers.push(n);
                }
            }
        });
        return callers;
    }
    return loadGraph()?.nodes.filter((n) => n.calls?.includes(targetId) ||
        n.inits?.includes(targetId) ||
        n.deinits?.includes(targetId)) ?? [];
}
function traceGraph(nodeId, depth, direction) {
    const visited = new Set();
    const edges = [];
    function walk(id, d) {
        if (d <= 0 || visited.has(id))
            return;
        visited.add(id);
        const node = findNode(id);
        if (!node)
            return;
        if (direction === "outgoing" || direction === "both") {
            for (const call of node.calls ?? []) {
                edges.push({ from: id, to: call });
                walk(call, d - 1);
            }
            for (const init of node.inits ?? []) {
                edges.push({ from: id, to: init });
                walk(init, d - 1);
            }
        }
        if (direction === "incoming" || direction === "both") {
            for (const caller of findCallers(id)) {
                edges.push({ from: caller.id, to: id });
                walk(caller.id, d - 1);
            }
        }
    }
    walk(nodeId, depth);
    return { nodes: Array.from(visited), edges };
}
const server = new McpServer({
    name: "swiftprism",
    version: "1.0.0",
});
server.resource("graph", "graph://entire", async (uri) => {
    // Prefer fragment index stats (no full load)
    const loader = getFragmentLoader();
    if (loader) {
        const stats = loader.getStats();
        if (stats) {
            return {
                contents: [{
                        uri: uri.href,
                        mimeType: "application/json",
                        text: JSON.stringify({ nodeCount: stats.nodeCount, fragmentCount: stats.fragmentCount, sharedCount: stats.sharedCount, generatedAt: stats.generatedAt, mode: "fragmented" }),
                    }],
            };
        }
    }
    const data = loadGraph();
    if (!data)
        return { contents: [{ uri: uri.href, mimeType: "text/plain", text: NOT_CONFIGURED_MSG }] };
    return {
        contents: [
            {
                uri: uri.href,
                mimeType: "application/json",
                text: JSON.stringify({
                    nodeCount: data.nodes.length,
                    targets: data.targets ?? [],
                    mode: "monolithic",
                    flavors: Object.fromEntries([...new Set(data.nodes.map((n) => n.flavor))].map((f) => [
                        f,
                        data.nodes.filter((n) => n.flavor === f).length,
                    ])),
                }),
            },
        ],
    };
});
server.resource("target", "target://{name}", async (uri) => {
    const name = new URL(uri.href).hostname || uri.href.replace("target://", "");
    const data = loadGraph();
    if (!data)
        return { contents: [{ uri: uri.href, mimeType: "text/plain", text: NOT_CONFIGURED_MSG }] };
    const nodes = data.nodes.filter((n) => n.id.startsWith(`${name}::`) || n.id === name);
    return {
        contents: [
            {
                uri: uri.href,
                mimeType: "application/json",
                text: JSON.stringify({
                    target: name,
                    nodeCount: nodes.length,
                    nodes: nodes.map((n) => ({
                        id: n.id,
                        name: n.name,
                        flavor: n.flavor,
                    })),
                }),
            },
        ],
    };
});
server.resource("file", "file://{filePath}", async (uri) => {
    const filePath = uri.href.replace("file://", "");
    const data = loadGraph();
    if (!data)
        return { contents: [{ uri: uri.href, mimeType: "text/plain", text: NOT_CONFIGURED_MSG }] };
    const nodes = data.nodes.filter((n) => n.location.absPath.endsWith(filePath) ||
        n.parents.some((p) => p === filePath || p === `file:${filePath}`));
    return {
        contents: [
            {
                uri: uri.href,
                mimeType: "application/json",
                text: JSON.stringify({
                    file: filePath,
                    nodeCount: nodes.length,
                    nodes: nodes.map((n) => ({
                        id: n.id,
                        name: n.name,
                        flavor: n.flavor,
                        line: n.location.line,
                    })),
                }),
            },
        ],
    };
});
server.tool("get_node_info", {
    node_id: z.string().describe("Full namespaced node ID (e.g. Cryptoday::AppDelegate::viewDidLoad())"),
    full_source: z.boolean().default(false).describe("If true, return full node data instead of pre-digested context"),
}, async ({ node_id, full_source }) => {
    const node = findNode(node_id);
    if (!node) {
        return { content: [{ type: "text", text: `Node not found: ${node_id}` }] };
    }
    return {
        content: [
            {
                type: "text",
                text: JSON.stringify(toTokenOptimized(node, full_source), null, 2),
            },
        ],
    };
});
server.tool("trace_dependency", {
    node_id: z.string().describe("Node ID to trace from"),
    depth: z.number().default(3).describe("Max traversal depth (default 3)"),
    direction: z.enum(["outgoing", "incoming", "both"]).default("both").describe("Trace direction"),
}, async ({ node_id, depth, direction }) => {
    const result = traceGraph(node_id, depth, direction);
    return {
        content: [
            {
                type: "text",
                text: JSON.stringify({
                    root: node_id,
                    depth,
                    direction,
                    reachableNodes: result.nodes.length,
                    nodes: result.nodes,
                    edges: result.edges,
                }, null, 2),
            },
        ],
    };
});
server.tool("find_impact_range", { node_id: z.string().describe("Node ID to analyze impact for") }, async ({ node_id }) => {
    const callers = findCallers(node_id);
    const node = findNode(node_id);
    const directCallers = callers.map((c) => ({
        id: c.id,
        name: c.name,
        flavor: c.flavor,
        file: c.location.absPath,
        line: c.location.line,
    }));
    const transitiveTrace = traceGraph(node_id, 5, "incoming");
    return {
        content: [
            {
                type: "text",
                text: JSON.stringify({
                    target: node_id,
                    targetFlavor: node?.flavor ?? "unknown",
                    directCallers,
                    transitiveImpact: transitiveTrace.nodes.length,
                    affectedNodes: transitiveTrace.nodes,
                    affectedFiles: [
                        ...new Set(transitiveTrace.nodes
                            .map((id) => findNode(id)?.location.absPath)
                            .filter(Boolean)),
                    ],
                }, null, 2),
            },
        ],
    };
});
server.tool("get_navigation_path", { node_id: z.string().describe("Node ID to navigate to") }, async ({ node_id }) => {
    const node = findNode(node_id);
    if (!node) {
        return { content: [{ type: "text", text: `Node not found: ${node_id}` }] };
    }
    const result = {
        primary: node.location,
    };
    if (node.locations && node.locations.length > 0) {
        result.extensions = node.locations;
    }
    return {
        content: [
            {
                type: "text",
                text: JSON.stringify({
                    node_id,
                    name: node.name,
                    flavor: node.flavor,
                    ...result,
                }, null, 2),
            },
        ],
    };
});
server.tool("get_contextual_subgraph", {
    query: z.string().describe("Natural language question about the codebase (e.g. 'How does article fetching work?')"),
    max_seeds: z.number().default(5).describe("Max seed nodes to discover"),
    depth: z.number().default(2).describe("Relationship expansion depth"),
    full_source: z.boolean().default(false).describe("If true, return full node data instead of pre-digested node_context"),
}, async ({ query, max_seeds, depth, full_source }) => {
    // ── Phase 0: Ensure fragments or load monolithic ──
    const loader = ensureFragments();
    const queryTokens = query
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, " ")
        .split(/\s+/)
        .filter((t) => t.length > 2);
    // ── Phase 1: Seed discovery (scan fragments one-at-a-time) ──
    const scored = [];
    function scoreNode(node) {
        let score = 0;
        const haystack = `${node.id} ${node.name} ${node.flavor}`.toLowerCase();
        for (const token of queryTokens) {
            if (haystack.includes(token))
                score += 10;
            if (node.name.toLowerCase() === token)
                score += 50;
            if (node.name.toLowerCase().includes(token))
                score += 20;
        }
        if (node.flavor === "class" || node.flavor === "struct" || node.flavor === "protocol")
            score += 3;
        if (node.flavor === "function" && (node.calls?.length ?? 0) > 0)
            score += 2;
        return score;
    }
    if (loader) {
        // Fragment mode: scan each file individually, score, discard
        loader.forEachFragment((nodes) => {
            for (const node of nodes) {
                const s = scoreNode(node);
                if (s > 0)
                    scored.push({ node, score: s });
            }
        });
    }
    else {
        // Monolithic fallback
        const data = loadGraph();
        if (!data || data.nodes.length === 0)
            return notConfiguredResponse();
        for (const node of data.nodes) {
            const s = scoreNode(node);
            if (s > 0)
                scored.push({ node, score: s });
        }
    }
    const seeds = scored
        .sort((a, b) => b.score - a.score)
        .slice(0, max_seeds)
        .map((s) => s.node);
    if (seeds.length === 0) {
        return {
            content: [{
                    type: "text",
                    text: JSON.stringify({ error: "No relevant nodes found for query", query }),
                }],
        };
    }
    // ── Phase 2: Stitch subgraph from seeds ──
    const seedIds = seeds.map((s) => s.id);
    let stitchedNodes;
    let missingRefs = [];
    if (loader) {
        // Fragment mode: stitch loads only needed files + shared globals
        const stitched = loader.stitch(seedIds, depth);
        stitchedNodes = stitched.nodes;
        missingRefs = stitched.missing;
    }
    else {
        // Monolithic fallback: BFS expansion in memory
        const data = loadGraph();
        if (!data)
            return notConfiguredResponse();
        const nodeById = new Map(data.nodes.map((n) => [n.id, n]));
        const collected = new Set();
        let frontier = new Set(seedIds);
        for (let d = 0; d <= depth; d++) {
            const next = new Set();
            for (const id of frontier) {
                if (collected.has(id))
                    continue;
                collected.add(id);
                const node = nodeById.get(id);
                if (!node) {
                    missingRefs.push(id);
                    continue;
                }
                for (const ref of [...(node.calls ?? []), ...(node.inits ?? []), ...(node.stores ?? [])]) {
                    if (!collected.has(ref))
                        next.add(ref);
                }
                for (const p of node.parents) {
                    if (p.includes("::") && !collected.has(p))
                        next.add(p);
                }
            }
            frontier = next;
        }
        stitchedNodes = data.nodes.filter((n) => collected.has(n.id));
    }
    // ── Phase 3: Classify into primary / relationship / shared ──
    const nodeById = new Map(stitchedNodes.map((n) => [n.id, n]));
    // Primary = seeds + their direct parents/calls
    const primaryIds = new Set(seedIds);
    for (const seed of seeds) {
        for (const p of seed.parents)
            if (nodeById.has(p))
                primaryIds.add(p);
        for (const c of seed.calls ?? [])
            if (nodeById.has(c))
                primaryIds.add(c);
        for (const i of seed.inits ?? [])
            if (nodeById.has(i))
                primaryIds.add(i);
    }
    // Shared = targets + multi-referenced
    const sharedIds = new Set();
    const refCounts = new Map();
    for (const node of stitchedNodes) {
        if (node.flavor === "target") {
            sharedIds.add(node.id);
            continue;
        }
        for (const ref of [...(node.calls ?? []), ...(node.inits ?? []), ...(node.stores ?? [])]) {
            refCounts.set(ref, (refCounts.get(ref) ?? 0) + 1);
        }
    }
    for (const [ref, count] of refCounts) {
        if (count >= 2 && nodeById.has(ref))
            sharedIds.add(ref);
    }
    function toFragment(id) {
        return toTokenOptimizedFragment(id, nodeById, full_source);
    }
    const relationshipIds = new Set(stitchedNodes.map((n) => n.id).filter((id) => !primaryIds.has(id) && !sharedIds.has(id)));
    const result = [
        { type: "primary", description: "Seed nodes and immediate connections", data: [...primaryIds].map(toFragment) },
        { type: "relationship", description: `Extended paths (depth ${depth})`, data: [...relationshipIds].map(toFragment) },
        { type: "shared", description: "Bridge nodes referenced by multiple fragments + targets", data: [...sharedIds].map(toFragment) },
    ];
    return {
        content: [{
                type: "text",
                text: JSON.stringify({
                    query,
                    mode: loader ? "fragmented" : "monolithic",
                    seedCount: seeds.length,
                    seeds: seeds.map((s) => ({ id: s.id, name: s.name, flavor: s.flavor })),
                    fragments: result,
                    stats: { primary: result[0].data.length, relationship: result[1].data.length, shared: result[2].data.length, total: result[0].data.length + result[1].data.length + result[2].data.length },
                    ...(missingRefs.length > 0 ? { missingFragments: missingRefs } : {}),
                }, null, 2),
            }],
    };
});
server.tool("generate_subgraph_files", {
    query: z.string().describe("Natural language question to generate sub-graph files for"),
    max_seeds: z.number().default(5).describe("Max seed nodes"),
    depth: z.number().default(2).describe("Dependency expansion depth"),
}, async ({ query, max_seeds, depth }) => {
    const paths = resolveProjectPaths();
    if (!paths)
        return notConfiguredResponse();
    const { generateSubGraph } = await import("./subgraph-agent.js");
    const outputBase = paths.contextsDir;
    const result = generateSubGraph(paths.graphPath, query, outputBase, max_seeds, depth);
    return {
        content: [{
                type: "text",
                text: JSON.stringify(result, null, 2),
            }],
    };
});
server.tool("load_context_fragments", {
    query_id: z.string().optional().describe("Specific query ID folder to load from. If omitted, loads the latest."),
    fragment_type: z.enum(["primary", "dependency", "shared", "all"]).default("primary").describe("Which fragment to load"),
}, async ({ query_id, fragment_type }) => {
    const paths = resolveProjectPaths();
    if (!paths) {
        return notConfiguredResponse();
    }
    const contextsDir = paths.contextsDir;
    if (!fs.existsSync(contextsDir)) {
        return {
            content: [{
                    type: "text",
                    text: "No context fragments found. Run generate_subgraph_files first, or run ./run.sh.",
                }],
        };
    }
    let targetDir;
    if (query_id) {
        targetDir = path.join(contextsDir, query_id);
    }
    else {
        const dirs = fs.readdirSync(contextsDir)
            .filter((d) => fs.statSync(path.join(contextsDir, d)).isDirectory())
            .sort((a, b) => {
            const aStat = fs.statSync(path.join(contextsDir, a));
            const bStat = fs.statSync(path.join(contextsDir, b));
            return bStat.mtimeMs - aStat.mtimeMs;
        });
        if (dirs.length === 0) {
            return {
                content: [{
                        type: "text",
                        text: "No sub-graph fragments generated yet. Call generate_subgraph_files first.",
                    }],
            };
        }
        targetDir = path.join(contextsDir, dirs[0]);
    }
    if (!fs.existsSync(targetDir)) {
        return {
            content: [{
                    type: "text",
                    text: `Fragment folder not found: ${targetDir}`,
                }],
        };
    }
    const result = {};
    const typesToLoad = fragment_type === "all"
        ? ["primary", "dependency", "shared_commons"]
        : [fragment_type === "shared" ? "shared_commons" : fragment_type];
    for (const prefix of typesToLoad) {
        const filePath = path.join(targetDir, `${prefix}.json`);
        if (fs.existsSync(filePath)) {
            result[prefix] = JSON.parse(fs.readFileSync(filePath, "utf-8"));
        }
    }
    return {
        content: [{
                type: "text",
                text: JSON.stringify({
                    folder: targetDir,
                    loaded: Object.keys(result),
                    stats: Object.fromEntries(Object.entries(result).map(([k, v]) => [k, v.length])),
                    data: result,
                }, null, 2),
            }],
    };
});
async function main() {
    // CRITICAL: Never call process.exit(). The server must stay alive
    // to keep the MCP connection green, even if data is missing.
    try {
        const transport = new StdioServerTransport();
        await server.connect(transport);
        const mode = STEALTH_MODE ? "stealth" : "standard";
        console.error(`[SwiftPrism MCP] Connected (mode: ${mode})`);
        const paths = resolveProjectPaths();
        if (paths) {
            // Auto-fragment at startup if monolithic graph exists but fragments don't
            const loader = ensureFragments();
            if (loader) {
                const stats = loader.getStats();
                console.error(`[SwiftPrism MCP] Fragments ready: ${stats?.nodeCount ?? "?"} nodes in ${stats?.fragmentCount ?? "?"} files`);
            }
            try {
                fs.watch(path.dirname(paths.graphPath), (_event, filename) => {
                    if (filename === path.basename(paths.graphPath)) {
                        console.error("[SwiftPrism MCP] Graph file changed — re-fragmenting...");
                        ensureFragments()?.invalidate();
                    }
                });
                console.error(`[SwiftPrism MCP] Watching: ${paths.graphPath}`);
            }
            catch {
                console.error("[SwiftPrism MCP] Could not watch graph file (non-fatal).");
            }
        }
        else {
            console.error("[SwiftPrism MCP] No graph data found. Tools will return guidance when called.");
            console.error("[SwiftPrism MCP] Run ./run.sh in the project root to generate data.");
        }
    }
    catch (err) {
        // Log but do NOT exit — keep the process alive for reconnection attempts
        console.error("[SwiftPrism MCP] Initialization error (non-fatal):", err);
    }
}
main().catch((err) => {
    // Last resort — log but never exit
    console.error("[SwiftPrism MCP] Fatal startup error:", err);
});
