import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
const SHARED_THRESHOLD = 3;
function loadGraph(graphPath) {
    const raw = fs.readFileSync(graphPath, "utf-8");
    const data = JSON.parse(raw);
    return data.nodes ?? data;
}
function buildSummary(nodes) {
    return nodes.map((n) => {
        const parts = [];
        if (n.flavor === "target")
            parts.push(`Target: ${n.name}`);
        else if (["struct", "class", "enum", "actor", "protocol"].includes(n.flavor)) {
            parts.push(`${n.flavor} ${n.name}`);
            if (n.extends)
                parts.push(`extends ${n.extends}`);
            if (n.implements?.length)
                parts.push(`implements ${n.implements.join(", ")}`);
            if (n.inits?.length)
                parts.push(`${n.inits.length} init deps`);
            if (n.stores?.length)
                parts.push(`stores ${n.stores.join(", ")}`);
        }
        else {
            parts.push(`${n.flavor} ${n.name}`);
            if (n.calls?.length)
                parts.push(`calls ${n.calls.length} functions`);
            if (n.returns?.length)
                parts.push(`returns ${n.returns.join(", ")}`);
            if (n.parameters?.length)
                parts.push(`params ${n.parameters.join(", ")}`);
        }
        return {
            id: n.id,
            name: n.name,
            flavor: n.flavor,
            desc: parts.join(" | "),
        };
    });
}
function scoreNodes(nodes, query) {
    const tokens = query
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, " ")
        .split(/\s+/)
        .filter((t) => t.length > 2);
    return nodes.map((node) => {
        let score = 0;
        const haystack = `${node.id} ${node.name} ${node.flavor}`.toLowerCase();
        for (const token of tokens) {
            if (node.name.toLowerCase() === token)
                score += 50;
            else if (node.name.toLowerCase().includes(token))
                score += 20;
            else if (haystack.includes(token))
                score += 10;
        }
        if (["class", "struct", "protocol", "actor"].includes(node.flavor))
            score += 3;
        if (node.flavor === "function" && (node.calls?.length ?? 0) > 0)
            score += 2;
        return { node, score };
    });
}
function collectPrimary(seeds, nodeMap) {
    const ids = new Set();
    for (const seed of seeds) {
        ids.add(seed.id);
        for (const p of seed.parents)
            if (nodeMap.has(p))
                ids.add(p);
        for (const c of seed.calls ?? [])
            ids.add(c);
        for (const i of seed.inits ?? [])
            ids.add(i);
        for (const d of seed.deinits ?? [])
            ids.add(d);
        for (const s of seed.stores ?? [])
            ids.add(s);
    }
    return ids;
}
function collectDependency(primaryIds, nodeMap, allNodes, depth) {
    const depIds = new Set();
    let frontier = new Set(primaryIds);
    for (let d = 0; d < depth; d++) {
        const next = new Set();
        for (const id of frontier) {
            const node = nodeMap.get(id);
            if (!node)
                continue;
            for (const ref of [...(node.calls ?? []), ...(node.inits ?? []), ...(node.stores ?? [])]) {
                if (!primaryIds.has(ref) && !depIds.has(ref)) {
                    depIds.add(ref);
                    next.add(ref);
                }
            }
            for (const caller of allNodes) {
                if (caller.calls?.includes(id) || caller.inits?.includes(id)) {
                    if (!primaryIds.has(caller.id) && !depIds.has(caller.id)) {
                        depIds.add(caller.id);
                        next.add(caller.id);
                    }
                }
            }
        }
        frontier = next;
    }
    return depIds;
}
function detectShared(primaryIds, depIds, nodeMap) {
    const refCount = new Map();
    const allIds = [...primaryIds, ...depIds];
    for (const id of allIds) {
        const node = nodeMap.get(id);
        if (!node)
            continue;
        for (const ref of [...(node.calls ?? []), ...(node.inits ?? []), ...(node.stores ?? []), ...(node.returns ?? []), ...(node.parameters ?? [])]) {
            refCount.set(ref, (refCount.get(ref) ?? 0) + 1);
        }
    }
    const sharedIds = new Set();
    for (const [id, count] of refCount) {
        if (count >= SHARED_THRESHOLD)
            sharedIds.add(id);
    }
    for (const id of [...primaryIds, ...depIds]) {
        const node = nodeMap.get(id);
        if (node?.flavor === "target")
            sharedIds.add(id);
    }
    return sharedIds;
}
function traceStartupPath(mainId, seedIds, nodeMap) {
    const seedSet = new Set(seedIds);
    const visited = new Set();
    const parentMap = new Map();
    const queue = [mainId];
    visited.add(mainId);
    while (queue.length > 0) {
        const current = queue.shift();
        if (seedSet.has(current) && current !== mainId) {
            const path = [];
            let walk = current;
            while (walk) {
                path.unshift(walk);
                walk = parentMap.get(walk);
            }
            return path;
        }
        const node = nodeMap.get(current);
        if (!node)
            continue;
        for (const next of [...(node.calls ?? []), ...(node.inits ?? [])]) {
            if (!visited.has(next)) {
                visited.add(next);
                parentMap.set(next, current);
                queue.push(next);
            }
        }
        if (visited.size > 500)
            break;
    }
    return [];
}
function toFragment(node, sharedIds) {
    if (!node)
        return null;
    const frag = { ...node };
    const markExternal = (refs) => {
        if (!refs)
            return refs;
        return refs.map((r) => (sharedIds.has(r) ? r : r));
    };
    frag.calls = markExternal(frag.calls);
    frag.inits = markExternal(frag.inits);
    frag.stores = markExternal(frag.stores);
    return frag;
}
export function generateSubGraph(graphPath, query, outputBase, maxSeeds = 5, depth = 2) {
    const nodes = loadGraph(graphPath);
    const nodeMap = new Map(nodes.map((n) => [n.id, n]));
    const queryId = crypto.createHash("sha256").update(query).digest("hex").slice(0, 12);
    const outputDir = path.join(outputBase, queryId);
    fs.mkdirSync(outputDir, { recursive: true });
    const summary = buildSummary(nodes);
    const summaryPath = path.join(outputDir, "project-summary.json");
    fs.writeFileSync(summaryPath, JSON.stringify(summary, null, 2));
    const scored = scoreNodes(nodes, query);
    const seeds = scored
        .filter((s) => s.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, maxSeeds)
        .map((s) => s.node);
    const primaryIds = collectPrimary(seeds, nodeMap);
    const mainNodes = nodes.filter((n) => n.id === "GLOBAL::MAIN" || n.id.startsWith("MAIN::") || n.flavor === "entry_point");
    for (const main of mainNodes) {
        const pathToSeed = traceStartupPath(main.id, seeds.map((s) => s.id), nodeMap);
        for (const id of pathToSeed)
            primaryIds.add(id);
    }
    const depIds = collectDependency(primaryIds, nodeMap, nodes, depth);
    const sharedIds = detectShared(primaryIds, depIds, nodeMap);
    const primaryNodes = [...primaryIds]
        .map((id) => toFragment(nodeMap.get(id), sharedIds))
        .filter(Boolean);
    const depNodes = [...depIds]
        .filter((id) => !primaryIds.has(id))
        .map((id) => toFragment(nodeMap.get(id), sharedIds))
        .filter(Boolean);
    const sharedNodes = [...sharedIds]
        .map((id) => toFragment(nodeMap.get(id), new Set()))
        .filter(Boolean);
    const primaryPath = path.join(outputDir, "primary.json");
    const depPath = path.join(outputDir, "dependency.json");
    const sharedPath = path.join(outputDir, "shared_commons.json");
    fs.writeFileSync(primaryPath, JSON.stringify(primaryNodes, null, 2));
    fs.writeFileSync(depPath, JSON.stringify(depNodes, null, 2));
    fs.writeFileSync(sharedPath, JSON.stringify(sharedNodes, null, 2));
    return {
        queryId,
        query,
        seeds: seeds.map((s) => s.id),
        outputDir,
        files: {
            summary: summaryPath,
            primary: primaryPath,
            dependency: depPath,
            shared: sharedPath,
        },
        stats: {
            primary: primaryNodes.length,
            dependency: depNodes.length,
            shared: sharedNodes.length,
            total: primaryNodes.length + depNodes.length + sharedNodes.length,
        },
    };
}
if (process.argv[1]?.endsWith("subgraph-agent.js") || process.argv[1]?.endsWith("subgraph-agent.ts")) {
    const graphPath = process.argv[2] ?? "prism-context.json";
    const query = process.argv[3] ?? "main entry point";
    const outputBase = process.argv[4] ?? "dist-graphs";
    if (!fs.existsSync(graphPath)) {
        console.error(`Graph file not found: ${graphPath}`);
        process.exit(1);
    }
    const result = generateSubGraph(graphPath, query, outputBase);
    console.log(JSON.stringify(result, null, 2));
}
