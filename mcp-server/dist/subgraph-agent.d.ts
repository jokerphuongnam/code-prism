interface SubGraphResult {
    queryId: string;
    query: string;
    seeds: string[];
    outputDir: string;
    files: {
        summary: string;
        primary: string;
        dependency: string;
        shared: string;
    };
    stats: {
        primary: number;
        dependency: number;
        shared: number;
        total: number;
    };
}
export declare function generateSubGraph(graphPath: string, query: string, outputBase: string, maxSeeds?: number, depth?: number): SubGraphResult;
export {};
