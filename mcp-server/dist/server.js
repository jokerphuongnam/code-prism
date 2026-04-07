#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as fs from "fs";
import * as path from "path";
function resolveProjectPaths() {
    const cwd = process.cwd();
    const cwdConfig = path.join(cwd, "swiftprism-config.json");
    if (fs.existsSync(cwdConfig)) {
        const cfg = JSON.parse(fs.readFileSync(cwdConfig, "utf-8"));
        if (cfg.graphPath && fs.existsSync(cfg.graphPath)) {
            return {
                graphPath: cfg.graphPath,
                contextsDir: cfg.contextsDir ?? path.join(path.dirname(cfg.graphPath), "contexts"),
                projectRoot: cwd,
            };
        }
    }
    let dir = cwd;
    for (let i = 0; i < 10; i++) {
        const candidate = path.join(dir, "swiftprism-config.json");
        if (fs.existsSync(candidate)) {
            const cfg = JSON.parse(fs.readFileSync(candidate, "utf-8"));
            if (cfg.graphPath && fs.existsSync(cfg.graphPath)) {
                return {
                    graphPath: cfg.graphPath,
                    contextsDir: cfg.contextsDir ?? path.join(path.dirname(cfg.graphPath), "contexts"),
                    projectRoot: dir,
                };
            }
        }
        const direct = path.join(dir, "prism-context.json");
        if (fs.existsSync(direct)) {
            return {
                graphPath: direct,
                contextsDir: path.join(dir, "out", "contexts"),
                projectRoot: dir,
            };
        }
        const parent = path.dirname(dir);
        if (parent === dir)
            break;
        dir = parent;
    }
    throw new Error("Please run ./run.sh in the project root to initialize the context fragments. " +
        "Searched from: " + cwd);
}
function loadGraph() {
    const { graphPath } = resolveProjectPaths();
    const raw = fs.readFileSync(graphPath, "utf-8");
    return JSON.parse(raw);
}
function loadFragments(contextsDir, prefix) {
    if (!fs.existsSync(contextsDir))
        return [];
    const files = fs.readdirSync(contextsDir).filter((f) => f.startsWith(prefix) && f.endsWith(".json"));
    const nodes = [];
    for (const file of files) {
        try {
            const raw = fs.readFileSync(path.join(contextsDir, file), "utf-8");
            const data = JSON.parse(raw);
            if (Array.isArray(data))
                nodes.push(...data);
        }
        catch { }
    }
    return nodes;
}
function findNode(id) {
    return loadGraph().nodes.find((n) => n.id === id);
}
function findNodesByParent(parentId) {
    return loadGraph().nodes.filter((n) => n.parents.includes(parentId));
}
function findCallers(targetId) {
    return loadGraph().nodes.filter((n) => n.calls?.includes(targetId) ||
        n.inits?.includes(targetId) ||
        n.deinits?.includes(targetId));
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
    const data = loadGraph();
    return {
        contents: [
            {
                uri: uri.href,
                mimeType: "application/json",
                text: JSON.stringify({
                    nodeCount: data.nodes.length,
                    targets: data.targets ?? [],
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
server.tool("get_node_info", { node_id: z.string().describe("Full namespaced node ID (e.g. Cryptoday::AppDelegate::viewDidLoad())") }, async ({ node_id }) => {
    const node = findNode(node_id);
    if (!node) {
        return { content: [{ type: "text", text: `Node not found: ${node_id}` }] };
    }
    return {
        content: [
            {
                type: "text",
                text: JSON.stringify(node, null, 2),
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
}, async ({ query, max_seeds, depth }) => {
    const data = loadGraph();
    if (data.nodes.length === 0) {
        return { content: [{ type: "text", text: "No graph data loaded." }] };
    }
    const queryTokens = query
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, " ")
        .split(/\s+/)
        .filter((t) => t.length > 2);
    const scored = data.nodes.map((node) => {
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
        return { node, score };
    });
    const seeds = scored
        .filter((s) => s.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, max_seeds)
        .map((s) => s.node);
    if (seeds.length === 0) {
        return {
            content: [{
                    type: "text",
                    text: JSON.stringify({ error: "No relevant nodes found for query", query, totalNodes: data.nodes.length }),
                }],
        };
    }
    const primaryIds = new Set();
    const relationshipIds = new Set();
    const nodeById = new Map(data.nodes.map((n) => [n.id, n]));
    for (const seed of seeds) {
        primaryIds.add(seed.id);
        for (const p of seed.parents) {
            const parent = nodeById.get(p);
            if (parent)
                primaryIds.add(parent.id);
        }
        for (const call of seed.calls ?? [])
            primaryIds.add(call);
        for (const init of seed.inits ?? [])
            primaryIds.add(init);
    }
    function expand(ids, d) {
        if (d <= 0)
            return;
        const newIds = [];
        for (const id of ids) {
            const node = nodeById.get(id);
            if (!node)
                continue;
            for (const call of node.calls ?? []) {
                if (!ids.has(call) && !primaryIds.has(call))
                    newIds.push(call);
            }
            for (const caller of findCallers(id)) {
                if (!ids.has(caller.id) && !primaryIds.has(caller.id))
                    newIds.push(caller.id);
            }
        }
        for (const id of newIds)
            relationshipIds.add(id);
        expand(relationshipIds, d - 1);
    }
    expand(primaryIds, depth);
    const sharedIds = new Set();
    const allReferencedIds = new Set();
    for (const id of [...primaryIds, ...relationshipIds]) {
        const node = nodeById.get(id);
        if (!node)
            continue;
        for (const ref of [...(node.calls ?? []), ...(node.inits ?? []), ...(node.stores ?? [])]) {
            if (allReferencedIds.has(ref)) {
                sharedIds.add(ref);
            }
            else {
                allReferencedIds.add(ref);
            }
        }
    }
    for (const id of [...primaryIds, ...relationshipIds]) {
        const node = nodeById.get(id);
        if (node?.flavor === "target")
            sharedIds.add(id);
    }
    function toFragment(id) {
        const node = nodeById.get(id);
        if (!node)
            return { id, name: id, flavor: "unknown" };
        return {
            id: node.id,
            name: node.name,
            flavor: node.flavor,
            parents: node.parents,
            calls: node.calls,
            returns: node.returns,
            parameters: node.parameters,
            location: node.location,
        };
    }
    const result = [
        {
            type: "primary",
            description: "Seed nodes directly relevant to the query and their immediate connections",
            data: [...primaryIds].map(toFragment),
        },
        {
            type: "relationship",
            description: `Extended execution paths (depth ${depth}) from seed nodes`,
            data: [...relationshipIds].filter((id) => !primaryIds.has(id)).map(toFragment),
        },
        {
            type: "shared",
            description: "Nodes referenced by multiple fragments (targets, singletons, shared utilities)",
            data: [...sharedIds].map(toFragment),
        },
    ];
    return {
        content: [{
                type: "text",
                text: JSON.stringify({
                    query,
                    seedCount: seeds.length,
                    seeds: seeds.map((s) => ({ id: s.id, name: s.name, flavor: s.flavor })),
                    fragments: result,
                    stats: {
                        primary: result[0].data.length,
                        relationship: result[1].data.length,
                        shared: result[2].data.length,
                        total: result[0].data.length + result[1].data.length + result[2].data.length,
                    },
                }, null, 2),
            }],
    };
});
server.tool("generate_subgraph_files", {
    query: z.string().describe("Natural language question to generate sub-graph files for"),
    max_seeds: z.number().default(5).describe("Max seed nodes"),
    depth: z.number().default(2).describe("Dependency expansion depth"),
}, async ({ query, max_seeds, depth }) => {
    const { generateSubGraph } = await import("./subgraph-agent.js");
    const paths = resolveProjectPaths();
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
    let paths;
    try {
        paths = resolveProjectPaths();
    }
    catch {
        return {
            content: [{
                    type: "text",
                    text: "Please run ./run.sh in the project root to initialize the context fragments.",
                }],
        };
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
    const transport = new StdioServerTransport();
    await server.connect(transport);
    try {
        const paths = resolveProjectPaths();
        fs.watch(path.dirname(paths.graphPath), (event, filename) => {
            if (filename === path.basename(paths.graphPath)) {
                console.error("[SwiftPrism MCP] Graph file changed — next request will reload.");
            }
        });
        console.error(`[SwiftPrism MCP] Watching: ${paths.graphPath}`);
    }
    catch {
        console.error("[SwiftPrism MCP] No graph data yet. Run ./run.sh in the project root to generate.");
    }
}
main().catch(console.error);
