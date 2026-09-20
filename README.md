# SwiftPrism 💎

**A High-Fidelity 3D Dependency Visualizer & Context Optimizer for Swift Developers.**

SwiftPrism transforms your Swift codebase into an interactive 3D force-directed graph rendered inside VS Code. It statically analyzes every symbol, traces every dependency — from function calls to `didSet` observers to `.xcassets` references — and generates token-optimized context maps that reduce AI agent costs by up to 96%.

---

## SwiftUI app (native viewer)

macOS app that works like **agents-holding**: pick a project → install/run a **backend plugin** → UI reads **SoT only** (`.swiftprism/prism-context.json` + `graph.sqlite`).

```bash
# 1) Build analyzer backend once
cd core && swift build -c release
cp .build/release/swift-prism-analyzer ../extension/bin/

# 2) Open the SwiftUI app
cd ../app
xcodegen generate   # if needed
open SwiftPrismApp.xcodeproj
# Run (⌘R). Try "LiteTrace demo" → Install backend → Analyze → SoT
```

- **UI** (`app/`): SceneKit 3D graph, search, inspector — never parses Swift itself  
- **Backend** (`backends/` + `core` binary): one `main` that writes SoT under `<project>/.swiftprism/`  
- Sample project: `~/Documents/Code/iOS/LiteTrace`

## 🎯 Core Value Propositions

### 3D Semantic Mapping
Visualize Classes, Structs, Actors, Protocols, and the hidden web of property observers (`willSet`/`didSet`), computed properties, and protocol conformances as distinct 3D shapes — spheres for instance members, boxes for statics, diamonds for computed, mini-spheres for observers — all color-coded by type.

### AI Context Optimization
Generate lightweight code "skeletons" (`prism-context.json`) containing only public/internal signatures, dependency edges, and asset references. AI agents read this instead of your full source, cutting token consumption from ~200K to ~8K for a typical project.

### Resource-to-Code Tracing
See exactly where your `.xcassets` images and colors are consumed. SwiftPrism detects `Image("logo")`, `UIColor(named: "primary")`, custom wrapper calls like `DesignSystem.getColor("accent")`, and even heuristic string-literal matches — all with confidence scoring.

### Universal Target Support
Automatically parses `Package.swift` to detect multi-target SPM packages, macro targets, Xcode projects, and standalone Swift files. Cross-module dependencies appear as distinct red edges in the graph.

### Swift Macro Intelligence
Identifies `@attached` and `@freestanding` macro definitions, infers their roles (`member`, `peer`, `accessor`, etc.), and tracks which declarations they expand into.

---

## 🏗️ Architecture

SwiftPrism follows a **three-layer** architecture: Swift AST analysis, VS Code 3D visualization, and MCP-based AI graph access.

```
swift-prism/
  core/             Swift CLI — SwiftSyntax two-pass analysis
  extension/        VS Code — React + Three.js 3D webview
  mcp-server/       MCP Server — graph access for AI (SQLite SoT + JSON fallback)
  .swiftprism/      Hidden data (auto-generated, gitignored)
    prism-context.json  Analyzer / webview interchange (JSON)
    graph.sqlite        SQLite SoT for MCP queries (nodes + edges)
    fragments/          Per-object JSON files for on-demand loading
    graph-index.json    Lightweight { nodeId → fragmentFile } map
    _targets.json       Target hub nodes (UIKit, Foundation, etc.)
    _shared.json        Bridge nodes referenced by 2+ logic flows
```

### Storage hybrid (JSON + SQLite)

- **JSON** (`prism-context.json`): written by the Swift analyzer; still used by the VS Code webview and as the interchange format.
- **SQLite** (`graph.sqlite`): imported after analysis (`./run.sh` or `npm run import-db -- <json> [out.sqlite]`). MCP prefers SQLite for `search_symbols`, `get_project_summary`, and in-memory load (with JSON fallback + auto-import).

### Execution-First Model

Only code with executable bodies becomes a graph node. Stored properties (`var name: String`) are forbidden from the graph — they exist only as `stores` metadata on their parent Object. This reduces node count by ~46% while preserving all dependency information.

### Stealth Dynamic Subgraph Extraction

The MCP server fragments the full graph into per-object files inside `.swiftprism/fragments/`. When Claude queries a subgraph, only the relevant fragments are loaded and stitched via reference-ID pointers. Multi-referenced nodes (used by 2+ logic flows) are automatically promoted to a shared bridge file. Nothing persists in server memory between requests.

### Target Hub System

Every imported framework and internal target becomes a hub node with origin metadata:
- **Apple SDK** (`"Apple"`) — UIKit, SwiftUI, Foundation
- **Remote Git** (`"https://..."`) — resolved from Package.resolved
- **Local External** (`"/path/..."`) — local SPM packages
- **Internal** (no origin) — managed by GLOBAL::MAIN entry points

---

## ⚙️ Tech Stack

| Layer | Technology |
|---|---|
| **Static Analysis** | Swift 5.10+, SwiftSyntax 510, SwiftParser |
| **Extension Host** | TypeScript, VS Code Extension API |
| **3D Visualization** | React 18, Three.js, 3d-force-graph, Framer Motion, Vite |
| **MCP Server** | TypeScript, `@modelcontextprotocol/sdk`, fragmented load-on-demand |
| **Graph Capabilities** | Dynamic subgraph extraction, impact analysis, stealth file management |
| **Build Tooling** | SPM, npm, tsc, Vite, Docker (multi-stage) |
| **Project Detection** | Package.swift AST parsing, .xcodeproj, Package.resolved |

---

## 🚀 Getting Started

### One-Click Build

```bash
git clone <repo-url> && cd swift-prism
./run.sh
```

This builds the Swift analyzer, TypeScript extension, MCP server, and generates fragmented graph data inside `.swiftprism/`. Press **F5** in VS Code to launch.

### Connect Claude via MCP

```bash
# Global install + Claude Desktop registration
cd mcp-server && npm link
npx @anthropic-ai/claude-code mcp add swiftprism -- swift-prism-mcp
```

For stealth mode (all data hidden in `.swiftprism/`):
```json
{
  "mcpServers": {
    "swiftprism": {
      "command": "swift-prism-mcp",
      "env": { "SWIFTPRISM_MODE": "stealth" }
    }
  }
}
```

### Manual Build (No Docker)

```bash
cd core && swift build -c release
cp .build/release/swift-prism-analyzer ../extension/bin/
cd ../extension && npm install && npx tsc
cd webview && npm install && npx vite build
```

---

## 📁 Directory Structure

```
swift-prism/
├── core/                                    Swift Analysis Engine
│   ├── Package.swift                        SPM manifest (swift-tools-version: 5.10)
│   └── Sources/SwiftPrismAnalyzer/
│       ├── main.swift                       CLI entry: --context, --find-dependents-of, --scan-targets
│       ├── Models.swift                     All data types: Node, Link, Resource, Target, Macro
│       ├── Errors.swift                     PrismError domain errors
│       ├── SymbolCollector.swift             Pass 1: AST → symbols (class/struct/func/var/init/observers)
│       ├── CallCollector.swift              Call-site reference extraction
│       ├── InheritanceCollector.swift        Protocol conformance & class inheritance
│       ├── ResourceScanner.swift            Filesystem scan: .xcassets, .json, .plist, .md
│       ├── ResourceRefCollector.swift        String literal detection in Image/Color/Bundle calls
│       ├── StaticResourcePropertyCollector.swift  Extension static property → asset mapping
│       ├── MacroCollector.swift             @attached/@freestanding macro detection & role inference
│       ├── PackageManifestParser.swift       Package.swift target parsing via SwiftSyntax
│       ├── TargetResolver.swift             Auto-detect: SPM / Xcode / Standalone project types
│       ├── DependencyResolver.swift          Pass 2: link resolution, cross-target, macro expansion
│       ├── SignatureCollector.swift          Public/internal signature extraction (no bodies)
│       └── ContextGenerator.swift           prism-context.json skeleton generator
│
├── extension/                               VS Code Extension Shell
│   ├── src/                                 Extension Host (Node.js)
│   │   ├── extension.ts                     Activation, process lifecycle, context persistence
│   │   ├── explorerViewProvider.ts          Webview HTML builder, postMessage bridge
│   │   ├── analyzerBridge.ts               Buffer-based spawn, progress parsing, CLI wrappers
│   │   ├── swiftFileDiscovery.ts            Workspace .swift file scanner
│   │   └── protocol.ts                     Shared TypeScript types
│   │
│   ├── webview/                             React App (Vite-bundled)
│   │   ├── src/
│   │   │   ├── App.tsx                      Root: LKG state, tab switching, context copy toast
│   │   │   ├── components/
│   │   │   │   ├── Header.tsx               Analyze button, stats, tab switcher, LKG badge
│   │   │   │   ├── GraphView.tsx            3D graph + node click → "Copy Context for AI"
│   │   │   │   ├── GuideView.tsx            Interactive guide with confidence badges + AI buttons
│   │   │   │   ├── JsonPreview.tsx          Raw JSON debug panel
│   │   │   │   └── StatusBar.tsx            Real-time phase tracking with progress bar
│   │   │   ├── design/theme.ts             Color/shape/size mappings for all node and link types
│   │   │   ├── hooks/useVscodeMessaging.ts  acquireVsCodeApi bridge
│   │   │   └── protocol.ts                 Webview-side types + message protocol
│   │   ├── vite.config.ts
│   │   └── index.html
│   │
│   ├── bin/                                 swift-prism-analyzer binary
│   ├── resources/prism.svg                  Activity Bar icon
│   └── package.json                         Extension manifest
│
├── Dockerfile                               Multi-stage: swift:5.10 → node:20
├── docker-compose.yml                       Dev container with volume mounts
├── run.sh                                   One-click build + context generation
├── .vscode/
│   ├── launch.json                          F5 configs for extension + Swift debugger
│   └── tasks.json                           Cmd+Shift+B build tasks
├── .devcontainer/devcontainer.json          Dev Container config
│
├── CONTEXT_STRATEGY.md                      Token optimization methodology
├── RESOURCE_MAPPING.md                      Asset matching logic documentation
├── UNIVERSAL_SCAN_LOGIC.md                  Multi-target & macro detection docs
└── DOCKER_GUIDE.md                          Container usage guide
```

---

## 📊 Token Efficiency Analytics

SwiftPrism's context generation system is designed to minimize token consumption when feeding project context to LLM agents.

### How It Works

| Step | What Happens | Token Impact |
|---|---|---|
| **1. Signature Extraction** | Collects only function signatures, type declarations, and variable annotations — no implementation bodies | ~50-100 tokens per file vs ~2000+ for full source |
| **2. Dependency Pruning** | Records only which symbols call which symbols — not the call-site code | Edges are ~10 tokens each |
| **3. External Package Filtering** | `--public-only-external` indexes only `public`/`open` APIs for third-party deps | 73-80% reduction for large dependencies |
| **4. Targeted Retrieval** | `--find-dependents-of` returns only the 3-5 files relevant to a symbol | Agent reads ~5 files instead of ~50 |

### Real-World Impact

| Scenario | Full Codebase | SwiftPrism Context | Reduction |
|---|---|---|---|
| 50-file app project | ~200,000 tokens | ~8,000-15,000 tokens | **92-96%** |
| 100-file multi-module package | ~500,000 tokens | ~15,000-25,000 tokens | **95-97%** |
| Feature-scoped query (single symbol) | ~200,000 tokens | ~3,000-5,000 tokens | **97-98%** |

### Context Flow

```
prism-context.json (persisted, ~2K tokens)
        │
        ▼
AI Agent reads skeleton ──► understands project structure
        │
        ▼
--find-dependents-of "HomeViewModel" (~200 tokens output)
        │
        ▼
Agent reads only 3 relevant files (~10K tokens)
        │
        ▼
Total: ~12K tokens  vs  ~200K for full codebase
```

### CLI Usage for AI Agents

```bash
swift-prism-analyzer --workspace . --scan-targets --context --output prism-context.json

swift-prism-analyzer --workspace . --scan-targets --find-dependents-of "HomeViewModel"
```

### Integration

Add to your `CLAUDE.md` or `.cursorrules`:

```
Read prism-context.json before modifying Swift files.
Use swift-prism-analyzer --find-dependents-of "<symbol>" to identify related files.
Only read files listed in the output.
```

---

## 🎨 Visual Design System

### Node Shapes

| Shape | Condition | Example |
|---|---|---|
| Sphere | Instance members | `func doWork()` |
| Box | Static members | `static func shared()` |
| Diamond | Computed property | `var count: Int { get }` |
| Mini-sphere | `willSet`/`didSet` observer | `didSet { refresh() }` |
| Large Box | `.xcassets` catalog | `Assets.xcassets` |
| Cylinder | Image asset | `logo.imageset` |
| Cone | Color asset | `primary.colorset` |
| Torus | Markdown file | `README.md` |

### Node Colors

| Type | Color |
|---|---|
| `struct` | `#4FC3F7` Light Blue |
| `class` | `#7E57C2` Purple |
| `enum` | `#FF8A65` Orange |
| `actor` | `#26A69A` Teal |
| `protocol` | `#FFD54F` Amber |
| `macro` | `#FF7043` Deep Orange |
| `didSet` | `#E040FB` Magenta |
| `willSet` | `#F48FB1` Pink |

### Edge Styles

| Link Type | Color | Style |
|---|---|---|
| `call` | Blue | Solid |
| `cross_target_dependency` | Red | Long dash `[10,4]` |
| `conformance` | Amber | Short dash `[4,4]` |
| `inheritance` | Purple | Dash `[8,4]` |
| `resource_link` | Cyan | Dash `[6,3]` |
| `macro_expansion` | Deep Orange | Dash `[5,2]` |
| `heuristic_link` | Orange | Dotted `[2,4]` |

---

## 🤖 MCP Server Tools

The MCP server exposes the graph to AI agents (Claude Desktop, Claude Code) via the Model Context Protocol.

| Tool | Description |
|------|-------------|
| `get_node_info` | Full node data by namespaced ID |
| `get_contextual_subgraph` | Dynamic subgraph from natural language query — loads only needed fragments |
| `trace_dependency` | BFS traversal with configurable depth and direction |
| `find_impact_range` | "What breaks if I change this?" — transitive caller analysis |
| `get_navigation_path` | Click-to-code locations including extension files |
| `generate_subgraph_files` | Write fragment JSONs for offline analysis |
| `load_context_fragments` | Load pre-generated fragments by query ID |

The server discovers graph data automatically by walking upward from CWD to find `.git`, then checking `.swiftprism/` for the hidden config and fragments. If data is missing, tools return guidance instead of crashing — the MCP connection stays green.

---

## 🔧 CLI Reference

```bash
swift-prism-analyzer [OPTIONS] [FILES...]

OPTIONS:
  --workspace <path>          Set workspace root for scanning
  --scan-targets              Auto-detect SPM/Xcode targets from Package.swift
  --public-only-external      Index only public APIs for external dependencies
  --context                   Generate prism-context.json skeleton (signatures only)
  --find-dependents-of <id>   Query dependency graph for a specific symbol
  --output <path>             Write output to file instead of STDOUT
```

---

## 📚 Documentation

| Document | Content |
|---|---|
| [CONTEXT_STRATEGY.md](CONTEXT_STRATEGY.md) | Token optimization methodology, AI agent integration patterns |
| [RESOURCE_MAPPING.md](RESOURCE_MAPPING.md) | Five-strategy asset matching: direct API, custom wrappers, static aliases, protocol conformers, heuristics |
| [UNIVERSAL_SCAN_LOGIC.md](UNIVERSAL_SCAN_LOGIC.md) | Multi-target detection, macro intelligence, cross-module linking, public-only filtering |
| [DOCKER_GUIDE.md](DOCKER_GUIDE.md) | Container setup, volume mounts, troubleshooting |
| [core/README.md](core/README.md) | Swift engine internals, two-pass pipeline, STDERR protocol |
| [extension/README.md](extension/README.md) | Extension architecture, LKG state, communication flow, design system |

---

## 📄 License

MIT
