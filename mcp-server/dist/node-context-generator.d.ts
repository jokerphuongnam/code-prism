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
interface GeneratorConfig {
    ollamaEndpoint: string;
    ollamaModel: string;
    maxConcurrent: number;
    timeoutMs: number;
    /** Flavors eligible for context generation */
    eligibleFlavors: Set<string>;
}
export interface GenerateResult {
    total: number;
    generated: number;
    cached: number;
    failed: number;
    usedLLM: boolean;
}
/**
 * Generate node_context for all eligible nodes in the graph.
 * Writes enriched nodes back to the graph file with `node_context` field.
 * Uses incremental caching — only regenerates when source file hash changes.
 */
export declare function generateNodeContexts(graphPath: string, outputDir: string, configOverrides?: Partial<GeneratorConfig>): Promise<GenerateResult>;
/**
 * Apply stealth compression to a node_context string.
 * Replaces common Swift terms with compact symbols.
 */
export declare function applyStealthCompression(context: string): string;
export {};
