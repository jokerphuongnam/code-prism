# SwiftPrism backends (plugins)

Backends are **installable CLIs**. Each backend has a single job:

```text
main(projectRoot) → write Source of Truth under <project>/.swiftprism/
```

The **UI never parses Swift**. It only:

1. Lets the user pick a project folder
2. Installs / runs a backend
3. Reads SoT data (`prism-context.json`, `graph.sqlite`, …) and visualizes / serves MCP

## SoT layout (per project)

```text
<project>/.swiftprism/          # gitignored
  prism-context.json            # interchange (analyzer / webview)
  graph.sqlite                  # preferred MCP / query SoT
  swiftprism-config.json        # optional paths
```

## Current backend: `swift`

| Item | Path |
|------|------|
| Binary | built from `../core` → `swift-prism-analyzer` |
| Install location (app) | `~/Library/Application Support/SwiftPrism/backends/swift/swift-prism-analyzer` |
| Contract | `swift-prism-analyzer --workspace <root> --context --output <root>/.swiftprism/prism-context.json <swift files…>` |

Optional SQLite import (Node MCP helper):

```bash
node ../mcp-server/dist/graph-db.js import \
  <root>/.swiftprism/prism-context.json \
  <root>/.swiftprism/graph.sqlite
```

## Adding another language backend later

Ship one executable with `main` that writes the **same SoT schema** (or a documented dialect). The SwiftUI app discovers backends by folder name under Application Support.
