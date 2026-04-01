# SwiftPrism Core — Static Analysis Engine

High-performance Swift CLI that parses `.swift` files using SwiftSyntax, extracts deep metadata (symbols, relationships, property observers), and streams structured JSON output to STDOUT. Designed to run as a standalone background worker process.

## Build

```bash
cd core
swift build -c release
```

Binary: `.build/release/swift-prism-analyzer`

## Usage

```bash
swift-prism-analyzer path/to/File1.swift path/to/File2.swift ...
```

Accepts one or more `.swift` file paths. Outputs JSON to STDOUT. Progress and diagnostics stream to STDERR as structured JSON.

## Architecture

### Streaming Worker Model

The analyzer is designed to be spawned as a background child process by the VS Code extension. It communicates via:

- **STDOUT**: Final JSON payload (single `AnalysisResult` object)
- **STDERR**: Structured progress messages, warnings, and errors as newline-delimited JSON

### STDERR Protocol

```json
{"_progress":{"phase":"scanning","processed":5,"total":42}}
{"_progress":{"phase":"resolving","processed":0,"total":1}}
{"_warning":"Skipping unreadable file: /path/to/broken.swift"}
{"_progress":{"phase":"complete","processed":1,"total":1}}
{"_error":"Cannot read file at: /invalid/path.swift"}
```

Phases: `scanning` → `resolving` → `encoding` → `complete`

### Two-Pass Analysis Pipeline

**Pass 1 — Symbol Collection** (`SymbolCollector.swift`)

| Flavor | Detected |
|---|---|
| `struct`, `class`, `enum`, `actor`, `protocol` | Type declarations with inheritance clauses |
| `function` | Free functions and methods, `isStatic` detection |
| `variable` | Stored/computed properties, `willSet`/`didSet` as sub-symbols |
| `initializer` | `init` declarations |

Each symbol records: `id`, `name`, `flavor`, `subKind`, `isStatic`, `access`, `parent`, `location` (file/line/column).

**Pass 2 — Dependency Resolution** (`DependencyResolver.swift`)

Runs `CallCollector` on each symbol body + `InheritanceCollector` on type declarations.

### Link Types

| Type | Meaning |
|---|---|
| `call` | Function/method invocation |
| `access` | Property read/write |
| `conformance` | Protocol conformance (`: SomeProtocol`) |
| `inheritance` | Class inheritance |
| `observer_trigger` | Stored property → `willSet`/`didSet` body |

## Output Schema (STDOUT)

```json
{
  "nodes": [
    {
      "id": "MyStruct.compute",
      "name": "compute",
      "flavor": "function",
      "subKind": null,
      "isStatic": false,
      "access": "internal",
      "parent": "MyStruct",
      "location": { "file": "Sources/App.swift", "line": 12, "column": 5 }
    }
  ],
  "links": [
    { "source_id": "MyStruct.compute", "target_id": "Helper.run", "type": "call" }
  ]
}
```

## Error Handling

All errors use the `PrismError` enum. Structured error JSON emitted to STDERR. Exit code 1 on fatal failure. Unreadable files are skipped with a warning rather than aborting the entire analysis.

## Performance

- Files are parsed incrementally — each file's AST is walked and discarded after symbol extraction to minimize peak memory usage
- Progress emitted per-file to STDERR allows the UI to remain responsive during large project scans
- Buffer-friendly: the extension collects STDOUT via `Buffer.concat()` to avoid string concatenation overhead
