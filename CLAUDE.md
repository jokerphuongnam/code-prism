# SwiftPrism — Project Rules

## Architecture

Three-layer monorepo:
- `core/` — Swift CLI (SwiftSyntax AST analysis)
- `extension/` — VS Code extension (React + Three.js 3D webview)
- `mcp-server/` — MCP server (fragmented graph access for Claude)

Swift binary outputs flat JSON (`FlatMapEntry[]`). Extension renders it as a 3D graph. MCP server fragments it into per-object files for on-demand AI access.

## Execution-First Rendering Model

**Only nodes with executable code blocks produce graph spheres.** This is the foundational rule.

### Allowed Node Types (Can Render)

| Flavor | Condition | Graph Role |
|---|---|---|
| `target` | Always | Primary hub ("Solar System" center) |
| `struct`, `class`, `enum`, `actor`, `protocol` | Always | Object container |
| `function` | Always | Executable member |
| `initializer` | Folded into parent `inits[]` | Not independent node |
| `entry_point` | Always | Glowing gold hub |
| `variable` with `willSet`/`didSet`/`computed`/`getter`/`setter` | Has body | Executable member |
| `macro` | Always | Executable member |

### Forbidden Node Types (Never Render)

| Flavor | SubKind | Reason |
|---|---|---|
| `variable` | `stored` or `null` | No executable body — metadata only |

Stored properties exist only as strings inside `parameters`/`returns` arrays of functional nodes, or as inferred relationships in the NodeDetailCard inspector. They must never appear as standalone spheres on the 3D graph.

### Filtering Chain (5 Layers)

1. **Swift AST** (`convertToFlatMap`) — hard skip stored variables from JSON output
2. **TS Bridge** (`analyzerBridge.ts flatWalkObject`) — `isStoredProperty()` skip
3. **GraphView** (`buildFullNodeList`) — `continue` before `GraphNode` creation
4. **Visibility** (`computeVisibility`) — exclude from visible set
5. **Render Gate** (`graphData` memo) — final `filter()` before graph construction

### Variable Visibility in Inspector

When a user inspects a function node, the NodeDetailCard may show parameter types and return types that reference stored properties. These are **labels/metadata** — not clickable graph nodes.

## Target Node Hierarchy

Target nodes have `flavor: "target"` and plain-name IDs (e.g., `"UIKit"`, `"SwiftPrismAnalyzer"`).

### Origin Categories

| Origin Value | Color | Category |
|---|---|---|
| `"Apple"` | Blue `#42A5F5` | Apple SDK |
| `https://...` or `*.git` | Orange `#FF9800` | Remote Git dependency |
| `/absolute/path/...` | Green `#66BB6A` | Local external dependency |
| *(omitted)* | Cyan `#80DEEA` | Internal project target |

Internal targets have no `origin` field — they are managed by `GLOBAL::MAIN` entry point nodes.

## Node ID Format

- **Target**: plain name (`"UIKit"`, `"Foundation"`)
- **Object**: `Target::ObjectName` (`"SwiftPrismAnalyzer::CallCollector"`)
- **Member**: `Target::ObjectName::memberName` (`"SwiftPrismAnalyzer::CallCollector::visit(_:)"`)
- **Global function**: `Target::FileName::funcName`

## Parent Rules

- Objects: `parents: ["FileName.swift"]` (single lexical parent — primary definition file)
- Members: `parents: ["Target::ObjectName"]` (exact Object ID)
- Target nodes: `parents: []` (root hubs)
- No `file:` prefix. No target name in parents of non-target nodes.

## Object Extension Handling

- Extension members attach to the primary Object ID via `parents[]`
- Each member's `location.absPath` points to the file where it is actually written
- Object nodes may have a `locations[]` array listing extension block positions for "Defined In" navigation
- No separate "Extension" nodes are created

## Data Sync Protocol

When new analysis data arrives (`analysisResult` or `mappingData` message):
1. Clear all state (`setResult(null)`, `setFlatEntries(null)`)
2. Tear down the force-graph instance (pause, destroy, clear DOM)
3. Apply new data on next tick
4. Reset `initialLoadDone` so the graph gets a fresh simulation

## MCP Server & Graph Fragmentation

### Stealth Discovery
The MCP server walks upward from CWD to find `.git`/`Package.swift`, then checks `.swiftprism/` for `swiftprism-config.json` and `graph-index.json`. In stealth mode (`SWIFTPRISM_MODE=stealth`), only `.swiftprism/` is checked — no visible root configs.

### Fragment Architecture
The monolithic graph is split into:
- `_targets.json` — target hub nodes
- `_shared.json` — bridge nodes referenced by 2+ logic flows
- `_globals.json` — top-level functions
- `ClassName.json` — per-object fragments

The `graph-index.json` maps `{ nodeId → fragmentFile }`. The server loads only the files it needs per request and stitches them via reference-ID pointers.

### Stay-Alive Protocol
The server NEVER calls `process.exit()`. If graph data is missing, all tools return guidance text and the MCP connection stays green.

## Removed Fields (Do Not Re-add)

- `sourceFiles` on Object nodes — use member `location.absPath` instead
- `file:` prefix on parent IDs — use plain filenames
- `connections` (deprecated) — use `calls[]`/`inits[]`/`deinits[]`
