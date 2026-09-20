import { DatabaseSync } from "node:sqlite";
import type { GraphNode } from "./fragment-store.js";
export declare const GRAPH_DB_FILENAME = "graph.sqlite";
export declare const SCHEMA_VERSION = "1";
export declare function sqlitePathBesideGraph(graphPath: string): string;
export declare function openGraphDb(dbPath: string, readonly?: boolean): DatabaseSync;
export declare function parseGraphJson(raw: string): GraphNode[];
/** Rebuild SQLite from a prism-context / graph JSON file. */
export declare function importGraphFromJson(graphPath: string, dbPath?: string): {
    dbPath: string;
    nodeCount: number;
    edgeCount: number;
};
export declare function rowToNode(row: {
    id: string;
    name: string;
    flavor: string;
    abs_path: string | null;
    line: number | null;
    col: number | null;
    extends: string | null;
    origin: string | null;
    node_context: string | null;
    json: string;
}): GraphNode;
export declare class GraphDatabase {
    readonly dbPath: string;
    private db;
    constructor(dbPath: string, readonly?: boolean);
    close(): void;
    meta(key: string): string | null;
    nodeCount(): number;
    edgeCount(): number;
    getNode(id: string): GraphNode | undefined;
    getNodes(ids: string[]): GraphNode[];
    /** Who points at this node via call/init/deinit. */
    findCallers(targetId: string): GraphNode[];
    searchSymbols(query: string, flavor: string | undefined, limit: number): {
        id: string;
        name: string;
        flavor: string;
        context: string | null;
    }[];
    flavorCounts(): Record<string, number>;
    targets(): {
        id: string;
        name: string;
        origin: string | null;
        context: string | null;
    }[];
    /** Load all nodes into memory maps (compat layer for existing MCP helpers). */
    loadAllIntoMemory(): {
        nodes: GraphNode[];
        nodeById: Map<string, GraphNode>;
        callerIndex: Map<string, string[]>;
    };
}
