# SwiftPrism Extension — React + 3D Visualization Shell

VS Code extension with a React-powered webview sidebar featuring 3D force-directed graph visualization, real-time progress tracking, and LKG (Last Known Good) state resilience.

## Architecture

```
extension/
├── src/                          # Extension Host (Node.js)
│   ├── extension.ts              # Activation, process lifecycle, command wiring
│   ├── explorerViewProvider.ts   # Serves React bundle, postMessage bridge
│   ├── analyzerBridge.ts         # Buffer-based spawn, progress parsing, error extraction
│   ├── swiftFileDiscovery.ts     # Workspace .swift file scanner
│   └── protocol.ts              # Shared types + progress protocol
│
├── webview/                      # React App (Vite-bundled)
│   ├── src/
│   │   ├── App.tsx               # Root: LKG state, tab switching, progress
│   │   ├── protocol.ts           # Shared types + message protocol
│   │   ├── hooks/
│   │   │   └── useVscodeMessaging.ts
│   │   ├── components/
│   │   │   ├── Header.tsx        # Analyze button, stats, LKG badge, tabs
│   │   │   ├── GraphView.tsx     # 3d-force-graph + Three.js custom shapes
│   │   │   ├── JsonPreview.tsx   # Raw JSON debug panel
│   │   │   └── StatusBar.tsx     # Phase indicator, progress bar, file counts
│   │   └── design/
│   │       └── theme.ts          # Color, shape, size, edge style mappings
│   └── vite.config.ts
│
├── dist-webview/                 # Vite output
├── out/                          # tsc output
└── bin/                          # swift-prism-analyzer binary
```

## Local Development (F5)

### Setup

```bash
cd extension && npm run install:all
cd ../core && swift build -c release
cp .build/release/swift-prism-analyzer ../extension/bin/
cd ../extension && npm run build
```

### Launch

1. Open root `swift-prism/` in VS Code
2. Press **F5** → **Run SwiftPrism Extension**
3. In the Extension Dev Host, open a Swift project
4. Click the prism icon → **▶ Analyze Project**

## Key Features

### Background Process Execution

The Swift analyzer runs as a spawned background process via `child_process.spawn`. The extension host:
- Collects STDOUT into `Buffer[]` (avoids string concatenation on large outputs)
- Parses STDERR progress messages in real-time and forwards to the React webview
- Kills previous process if a new analysis is triggered
- Cleans up on extension deactivation

### LKG (Last Known Good) State

If the analyzer crashes or returns an error during a re-analysis, React retains the previous valid graph in `lkgResult` ref. The UI shows:
- The cached graph with a `(cached)` badge in the header
- The error message in a banner above the graph
- The status bar shows `Error` phase

This prevents the user from losing their visualization due to transient failures.

### Real-time Status Bar

The bottom status bar shows live analysis progress:

| Phase | Display |
|---|---|
| `idle` | Green dot, "Ready" |
| `scanning` | Blue dot, "Scanning files 12/42 (29%)" with progress bar |
| `resolving` | Blue dot, "Resolving dependencies" |
| `streaming` | Blue dot, "Streaming data" with indeterminate bar |
| `complete` | Green dot, "Ready" |
| `error` | Red dot, "Error" |

## Communication Protocol

```
Extension Host                          React Webview
──────────────                          ─────────────
spawn binary
  ├─ stderr: {"_progress":...}  ──▶     progress message  ──▶ StatusBar
  ├─ stderr: {"_warning":...}   ──▶     vscode warning toast
  └─ stdout: Buffer[]
       ├─ concat + JSON.parse
       └─ postMessage ──────────────▶   analysisResult     ──▶ GraphView/JsonPreview
                                                                 └─ save to LKG ref
                       ◀────────────    analyzeRequest     ◀──  Header button click
```

## Design System

### Nodes

| Shape | Condition | Example |
|---|---|---|
| Sphere | Instance members | `func doWork()` |
| Box | `isStatic: true` | `static func shared()` |
| Diamond | `computed` property | `var count: Int { get }` |
| Mini-sphere | `willSet`/`didSet` | `didSet { refresh() }` |

### Colors

| Target | Color |
|---|---|
| `struct` | `#4FC3F7` |
| `class` | `#7E57C2` |
| `enum` | `#FF8A65` |
| `actor` | `#26A69A` |
| `protocol` | `#FFD54F` |
| `didSet` | `#E040FB` Magenta |
| `willSet` | `#F48FB1` Pink |

### Edges

| Type | Style |
|---|---|
| `call`, `access` | Solid |
| `conformance`, `observer_trigger` | Dashed `[4,4]` |
| `inheritance` | Dashed `[8,4]` |
