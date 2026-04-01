# Context Strategy — How SwiftPrism Optimizes Token Usage for AI Agents

## Problem

When an AI agent (Cursor, Claude, Copilot) needs to modify a feature in a Swift project, it typically requires the entire codebase context or relies on naive file-level retrieval. A 50-file project can consume 200K+ tokens just to provide enough context for a single feature change.

## Solution: Dependency-Aware Context Pruning

SwiftPrism generates a `prism-context.json` — a lightweight project skeleton that contains **only signatures** (no function bodies) plus a complete **dependency graph** and **asset map**. An AI agent reads this file to understand the project structure, then requests only the files it actually needs.

### Token Savings

| Approach | Tokens for 50-file project | Savings |
|---|---|---|
| Full codebase dump | ~200,000 | — |
| File-level retrieval (10 files) | ~40,000 | 80% |
| **SwiftPrism context + targeted files** | ~8,000-15,000 | **92-96%** |

### How the Savings Work

1. `prism-context.json` contains ~50-100 tokens per file (signatures only, no bodies)
2. The dependency index tells the agent exactly which 3-5 files are relevant
3. The agent reads only those files in full
4. Total: skeleton (~2K tokens) + targeted files (~6-13K tokens)

## Architecture

### 1. The Mapping Engine (`--context` mode)

```bash
swift-prism-analyzer --workspace /path/to/project --context --output prism-context.json *.swift
```

Generates a `PrismContext` with:

- **`files[]`**: Per-file list of public/internal signatures (no body code)
- **`assetMap[]`**: Every Image/Color asset mapped to its usage points
- **`dependencyIndex{}`**: Bidirectional adjacency list for the entire project

### prism-context.json Schema

```json
{
  "version": "1.0",
  "generatedAt": "2026-04-01T12:00:00Z",
  "files": [
    {
      "path": "Sources/HomeViewModel.swift",
      "signatures": [
        {
          "id": "HomeViewModel",
          "signature": "internal class HomeViewModel: ObservableObject",
          "line": 5,
          "dependencies": ["HomeService.fetchData", "UserDefaults.standard"],
          "resources": ["asset:Assets/home_banner"]
        },
        {
          "id": "HomeViewModel.loadData",
          "signature": "internal func loadData() -> Void",
          "line": 12,
          "dependencies": ["HomeService.fetchData"],
          "resources": []
        }
      ]
    }
  ],
  "assetMap": [
    {
      "assetId": "asset:Assets/home_banner",
      "assetName": "home_banner",
      "assetType": "image_set",
      "usedBy": ["HomeViewModel.loadData", "HomeView.body"]
    }
  ],
  "dependencyIndex": {
    "HomeViewModel": ["HomeService", "UserDefaults", "HomeView"],
    "HomeService": ["NetworkClient", "HomeViewModel"]
  }
}
```

### 2. Deep Linking: CLI Query

```bash
swift-prism-analyzer --find-dependents-of "HomeViewModel" --workspace . *.swift
```

Returns:
```json
{
  "direct": ["HomeService", "HomeView", "HomeCoordinator"],
  "transitive": ["NetworkClient", "APIConfig", "UserSession"],
  "files": ["Sources/HomeViewModel.swift", "Sources/HomeService.swift", "Sources/HomeView.swift"],
  "resources": ["asset:Assets/home_banner", "asset:Assets/primary"]
}
```

An AI agent can use this to build a minimal prompt:
- Read `prism-context.json` once (cached, ~2K tokens)
- Query `--find-dependents-of "HomeViewModel"` (instant, ~200 tokens output)
- Read only the 3 files listed in `files[]` (~10K tokens)
- **Total: ~12K tokens vs ~200K for full codebase**

### 3. VS Code Integration: "Copy Context for AI"

In the 3D graph, clicking any node reveals a panel with a **"Copy Context for AI"** button. This:

1. Runs `--find-dependents-of` for the selected node
2. Generates a Markdown prompt with:
   - Related file paths
   - Direct and transitive dependencies
   - Resource IDs
   - The CLI command to reproduce
3. Copies to clipboard
4. Shows estimated token count

### 4. Automatic Persistence

- **On every analysis**: The extension writes `prism-context.json` to the workspace root
- **`run.sh`**: Automatically regenerates the context file after every build
- **No re-scan needed**: AI agents can read `prism-context.json` directly from disk

## Data Pruning Strategy

### What is Included

- Type declarations with inheritance clauses
- Function signatures (name, parameters, return type)
- Variable declarations with type annotations
- Initializer signatures
- Access levels (public/internal only — private/fileprivate filtered out)
- Cross-references: which function calls which function
- Asset references: which function uses which image/color

### What is Excluded

- Function bodies (the actual implementation code)
- Private/fileprivate symbols (internal API surface only)
- Trivia (comments, whitespace, formatting)
- Import statements
- Macro expansions

### Why This Works

AI agents need to understand **what exists** and **what connects to what** before deciding **what to read in full**. The skeleton provides both:

1. **Existence**: "HomeViewModel has a `loadData()` method that returns Void"
2. **Connectivity**: "loadData depends on HomeService.fetchData and uses asset:home_banner"
3. **Location**: "HomeViewModel is in Sources/HomeViewModel.swift at line 5"

The agent can then make an informed decision: "I need to modify `loadData`, so I'll read HomeViewModel.swift and HomeService.swift — nothing else."

## Integration with AI Agents

### Cursor / Claude Code

Add to `.cursorrules` or `CLAUDE.md`:

```
Before modifying any Swift file, read prism-context.json to understand the dependency graph.
Use `swift-prism-analyzer --find-dependents-of "<symbol>"` to identify related files.
Only read files listed in the "files" output.
```

### Copilot Workspace

The `prism-context.json` file is automatically indexed by Copilot Workspace when placed at the project root.

### Custom Agents

```python
import json
import subprocess

context = json.load(open("prism-context.json"))

result = subprocess.run(
    ["swift-prism-analyzer", "--find-dependents-of", "HomeViewModel", "--workspace", ".", *swift_files],
    capture_output=True, text=True
)
deps = json.loads(result.stdout)

files_to_read = deps["files"]
```

## Persistence & Caching

| Trigger | Action |
|---|---|
| `./run.sh` | Regenerates `prism-context.json` |
| "Analyze Project" in VS Code | Regenerates `prism-context.json` |
| AI agent CLI query | Reads cached file, no re-scan |
| File save (future) | Incremental update via file watcher |

The context file is deterministic — same source code always produces the same output. It can be committed to version control for CI/CD agents.
