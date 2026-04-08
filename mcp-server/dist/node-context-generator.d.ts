/**
 * node-context-generator.ts — Entity-Aware LLM Pre-Processing Pipeline
 *
 * Two-pass enrichment with flavor-specific semantic templates:
 *   Pass 1: Leaf nodes (functions, macros, entry_points, targets)
 *   Pass 2: Parent nodes (classes, structs, enums, actors, protocols)
 *           — context incorporates children's resolved summaries
 *
 * Token templates per flavor:
 *   Function:  f:name|i:intent|p:params|d:deps|s:side_effects
 *   Class:     c:name|resp:responsibility|state:fields|d:deps
 *   Struct:    s:name|p:fields|i:data_purpose
 *   Protocol:  i:name|contract:behaviors|req:methods
 *   Enum:      e:name|cases:a,b,c|i:purpose
 *   Target:    lib:name|role:project_role|usage:features
 *
 * Usage:
 *   node dist/node-context-generator.js <graph-path> [--ollama-model codellama]
 */
interface GeneratorConfig {
    ollamaEndpoint: string;
    ollamaModel: string;
    maxConcurrent: number;
    timeoutMs: number;
    eligibleFlavors: Set<string>;
}
export interface GenerateResult {
    total: number;
    generated: number;
    cached: number;
    failed: number;
    usedLLM: boolean;
}
export declare function generateNodeContexts(graphPath: string, outputDir: string, configOverrides?: Partial<GeneratorConfig>): Promise<GenerateResult>;
export declare function applyStealthCompression(context: string): string;
export {};
