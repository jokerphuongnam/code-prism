# swift-prism

**Swift language backend** for Code Prism.

`main` analyzes Swift → writes **SoT** under the target project:

```text
<project>/.codeprism/
  prism-context.json
  graph.sqlite            # via mcp-prism graph-db import
  codeprism-config.json
```

This repo is **not** a UI. Viewers and MCP are separate:

| Repo | Role |
|------|------|
| **swift-prism** (this) | Swift analyzer backend |
| [marlin-prism](https://github.com/jokerphuongnam/marlin-prism) | Marlin backend |
| [kotlin-prism](https://github.com/jokerphuongnam/kotlin-prism) | Kotlin backend |
| [js-prism](https://github.com/jokerphuongnam/js-prism) | JS/TS backend |
| [mcp-prism](https://github.com/jokerphuongnam/mcp-prism) | MCP reads SoT (all languages) |
| [code-prism-app-mac](https://github.com/jokerphuongnam/code-prism-app-mac) | macOS SceneKit UI |
| [code-prism-vs-code](https://github.com/jokerphuongnam/code-prism-vs-code) | VS Code extension |

## Build

```bash
cd core && swift build -c release
# binary: core/.build/release/swift-prism-analyzer
```

## Analyze a project

```bash
BIN=core/.build/release/swift-prism-analyzer
ROOT=/path/to/project
mkdir -p "$ROOT/.codeprism"
$BIN --workspace "$ROOT" --scan-targets --public-only-external --context \
  --output "$ROOT/.codeprism/prism-context.json" \
  $(find "$ROOT" -name '*.swift' -not -path '*/.build/*' -not -path '*/DerivedData/*')

# optional SQLite SoT
node ../mcp-prism/dist/graph-db.js import \
  "$ROOT/.codeprism/prism-context.json" \
  "$ROOT/.codeprism/graph.sqlite"
```

Or use `./run.sh` from this repo (builds + generates for the current folder).

## Layout

```text
core/           SwiftSyntax analyzer
backends/       Plugin contract notes
run.sh          Build helper
```
