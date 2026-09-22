# Universal Scan Logic — Multi-Target, Macro, and Cross-Module Analysis

SwiftPrism supports three project archetypes: SPM packages (single and multi-target), Xcode projects, and standalone Swift files. This document explains how targets are detected, macros are tracked, cross-module dependencies are linked, and external packages are pruned for token efficiency.

## 1. Multi-Target Detection

### Auto-Detection Flow (`TargetResolver`)

Target discovery is the **first step** in v3.1. All subsequent nodes (objects, functions, resources) are grouped under the target they belong to. The output is strictly hierarchical — flat node arrays are prohibited.

```
Workspace Root
├── Package.swift exists?  → SPM Package mode
│   ├── Parse Package.swift AST for .executableTarget / .target / .testTarget / .macro / .plugin
│   ├── Resolve paths: custom `path:` or default Sources/<name>, Tests/<name>
│   ├── Discover nested Package.swift files → local sub-packages
│   └── Merge all targets → each target becomes a top-level container in the output
├── *.xcodeproj / *.xcworkspace exists?  → Xcode Project mode
│   ├── Scan Sources/ subdirectories as targets
│   └── Collect root-level .swift files as app target
└── Neither?  → Standalone mode
    └── All .swift files in root → single "unknown" target
```

### Package.swift Parsing (`PackageManifestParser`)

The parser uses SwiftSyntax to walk the `Package.swift` AST. It detects these target factory methods:

| Method | Target Type |
|---|---|
| `.executableTarget(name:...)` | `executable` |
| `.target(name:...)` | `library` |
| `.testTarget(name:...)` | `test` |
| `.macro(name:...)` | `macro` |
| `.plugin(name:...)` | `plugin` |

For each target, the parser extracts:
- `name`: from the `name:` argument
- `path`: from `path:` argument, or defaults to `Sources/<name>` / `Tests/<name>`
- `dependencies`: parsed from the `dependencies:` array, handling `.product(name:)`, `.target(name:)`, `.byName(name:)`, and string literals

### File-to-Target Mapping

Every symbol gets a `targetName` field by checking which target's directory contains its source file. Symbols are nested inside their owning target's `objects`, `freestandingFunctions`, or `resources` arrays — never in flat top-level arrays.

## 2. Swift Macro Intelligence

### Macro Definition Detection (`MacroCollector`)

Two types of macro definitions are detected:

**Freestanding Macros**
```swift
macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(...)
```
Detected via `MacroDeclSyntax` nodes.

**Attached Macros (Implementation Types)**
```swift
struct AddInitMacro: MemberMacro {
    static func expansion(...) -> [DeclSyntax] { ... }
}
```
Detected when a struct/class conforms to any of these protocols:
`ExpressionMacro`, `DeclarationMacro`, `AccessorMacro`, `MemberMacro`, `PeerMacro`, `MemberAttributeMacro`, `ConformanceMacro`, `ExtensionMacro`, `CodeItemMacro`, `BodyMacro`, `PreambleMacro`

### Macro Role Inference

Each macro implementation is assigned a `MacroRole` based on its protocol conformance:

| Protocol | Role |
|---|---|
| `PeerMacro` | `peer` |
| `MemberMacro` | `member` |
| `AccessorMacro` | `accessor` |
| `MemberAttributeMacro` | `memberAttribute` |
| `ConformanceMacro` | `conformance` |
| `ExpressionMacro` | `expression` |
| `DeclarationMacro` | `declaration` |
| `ExtensionMacro` | `extension` |

### Macro Application Tracking

When a non-builtin attribute is applied to a declaration, a `macro_expansion` link is created:

```swift
@AddInit        // → macro_expansion: AddInit → MyModel
struct MyModel {
    let name: String
}
```

The `MacroCollector` maintains a list of 40+ known built-in attributes (`@available`, `@objc`, `@MainActor`, `@State`, etc.) to avoid false positives.

### Generated Symbol Tracking

Each `MacroNode` in the output includes a `generatedSymbols` array listing all declarations the macro is applied to. This maps macro definitions to their expansion sites.

## 3. Cross-Module Linking

### Detection

When the `DependencyResolver` finds a call from symbol A in target X to symbol B in target Y (where X ≠ Y), it creates a `cross_target_dependency` link instead of a regular `call` link.

```json
{
  "source_id": "AppView.body",
  "target_id": "NetworkKit.APIClient.fetch",
  "type": "cross_target_dependency",
  "confidence": null
}
```

### How It Works

1. `TargetResolver` maps each file to its target
2. `SymbolCollector` tags each symbol with its `targetName`
3. `DependencyResolver` builds a `symbolTargetMap` and compares source vs destination target for every call

### Visual Representation

| Link Type | Color | Dash Pattern | Width |
|---|---|---|---|
| `cross_target_dependency` | `#EF5350` Red | `[10, 4]` | 2.5 |
| `macro_expansion` | `#FF7043` Deep Orange | `[5, 2]` | 1.5 |

## 4. Token Efficiency for External Packages

### Public-Only Indexing (`--public-only-external`)

When this flag is set, external dependencies (targets whose path contains `.build/checkouts` or `SourcePackages`) are indexed in public-API-only mode:

- Only `public`, `open`, and `package` symbols are included in the output nodes
- `private` and `fileprivate` symbols are filtered out entirely
- `internal` symbols in external targets are also excluded

This dramatically reduces output size for large dependencies like Alamofire, SwiftUI previews, or other third-party code.

### Impact

| Scenario | Full Index | Public-Only | Savings |
|---|---|---|---|
| Alamofire (~200 symbols) | ~200 nodes | ~40 nodes | 80% |
| SwiftSyntax (~2000 symbols) | ~2000 nodes | ~500 nodes | 75% |
| Typical 5-package project | ~3000 nodes | ~800 nodes | 73% |

## 5. CLI Flags

| Flag | Description |
|---|---|
| `--workspace <path>` | Set the workspace root for scanning |
| `--scan-targets` | Enable multi-target detection from Package.swift |
| `--public-only-external` | Index only public APIs for external packages |
| `--context` | Generate pruned `prism-context.json` skeleton |
| `--find-dependents-of <id>` | Query dependency graph for a specific symbol |
| `--output <path>` | Write output to file instead of stdout |

### Examples

```bash
swift-prism-analyzer --workspace . --scan-targets *.swift

swift-prism-analyzer --workspace . --scan-targets --public-only-external --context --output prism-context.json

swift-prism-analyzer --workspace . --scan-targets --find-dependents-of "HomeViewModel"
```

## 6. Output Schema Extensions

### AnalysisResult (v3.1-scope-stack)

The output is **target-centric and hierarchical**. There are no top-level flat `nodes[]` or `links[]` arrays. Every object, function, and resource is nested inside its owning target. Node IDs follow the `Target::File::Object::Member` namespace pattern.

Stored properties (`let x: Int`, `var name: String`) are **excluded** — they have no execution body and produce no nodes. Only executable blocks appear in the output.

```json
{
  "schemaVersion": "4.0-flat-graph",
  "projectRoot": "/path/to/project",
  "targets": [
    {
      "name": "MyApp",
      "type": "executable",
      "path": "Sources/MyApp",
      "dependencies": ["NetworkKit"],
      "isExternal": false,
      "entryPoint": {
        "id": "GLOBAL::MAIN",
        "kind": "@main",
        "location": { "line": 1, "col": 1, "absPath": "/path/MyApp.swift" },
        "parents": ["MyApp"],
        "calls": [{ "target": "MyApp::HomeViewModel", "location": {} }]
      },
      "resources": []
    }
  ],
  "nodes": [
    {
      "id": "MyApp::HomeViewModel",
      "name": "HomeViewModel",
      "flavor": "class",
      "location": { "line": 5, "col": 1, "absPath": "/path/HomeViewModel.swift" },
      "parents": ["HomeViewModel.swift"],
      "calls": [],
      "locations": [
        { "absPath": "/path/HomeViewModel.swift", "line": 5, "col": 1, "type": "primary" },
        { "absPath": "/path/HomeViewModel+Net.swift", "line": 3, "col": 1, "type": "extension" }
      ],
      "sourceFiles": ["HomeViewModel.swift", "HomeViewModel+Net.swift"],
      "extends": null,
      "implements": ["SwiftUI::ObservableObject"],
      "inits": ["MyApp::HomeViewModel::init()"],
      "deinits": []
    },
    {
      "id": "MyApp::HomeViewModel::init()",
      "name": "init()",
      "flavor": "initializer",
      "location": { "line": 8, "col": 5, "absPath": "/path/HomeViewModel.swift" },
      "parents": ["MyApp::HomeViewModel"],
      "calls": [{ "target": "NetworkKit::HomeService", "location": {} }]
    },
    {
      "id": "MyApp::HomeViewModel::loadData(id:)",
      "name": "loadData(id:)",
      "flavor": "function",
      "location": { "line": 20, "col": 5, "absPath": "/path/HomeViewModel.swift" },
      "parents": ["MyApp::HomeViewModel"],
      "calls": [{ "target": "NetworkKit::HomeService::fetchData()", "location": {} }]
    }
  ]
}
```

External frameworks (SPM/CocoaPods) are represented as single target nodes with an `isExternal: true` flag. They produce no deep objects.

### PrismContext (v3.1)

The context skeleton is saved to `context.globalStorageUri/cache/`, never to the project root. It includes:

- `schemaVersion`: `"3.1-scope-stack"`
- `projectType`: `"swift_package"`, `"multi_target_package"`, `"swift_macro_package"`, `"swift_app"`, or `"standalone"`
- `targets[]`: Per-target summary with file count, dependencies, and nested objects
- `macroMap[]`: Macro name, type, role, and list of applied-to symbols

## 7. v3.1 Architecture Rules

The v3.1 "Scope-Stack & Execution-First" schema enforces five mandatory rules. Flat structures (`nodes[]`, `links[]`) are deprecated. Node IDs follow the `Target::File::Object::Member` namespace.

### Rule 1: Target-Centricity

Every node MUST belong to a Target. There are no orphan nodes at the top level. External frameworks (SPM dependencies, CocoaPods) are represented as single target nodes with a `from` attribute indicating the source URL or local path. If a file cannot be mapped to any target, it is placed under a synthetic `"unknown"` target.

### Rule 2: Execution-Body Only

Only nodes that have a code body receive a `calls` array. This includes: `func`, `init`, `deinit`, property accessors (`get`, `set`, `willSet`, `didSet`), and SwiftUI `var body`. Stored properties (e.g. `let x: Int`, `var name: String`) are **excluded entirely** — they produce NO nodes in the output. Property observers (`willSet`/`didSet`) are promoted as individual member nodes named `propertyName.willSet` / `propertyName.didSet`. This rule keeps the graph focused on executable code paths.

### Rule 3: Object Schema

Objects (Class, Struct, Enum, Actor) must use dedicated `inits: []` and `deinits: []` arrays instead of placing initializers and deinitializers in the generic `members` array. This makes constructor/destructor relationships explicit and queryable without filtering.

### Rule 4: Ancestry

Every node must track its full ancestry via `parents: [ID]`, a snapshot of the scope stack `[Target, File, Object, Member]`. For example, a method inside a class has `parents: ["MyApp", "HomeViewModel.swift", "HomeViewModel", "loadData"]`. The object itself gets `parents: ["MyApp", "HomeViewModel.swift"]` (without self). This enables upward traversal without requiring tree walks.

### Rule 5: Source Mapping

All internal executable nodes must include a `position: { line, col, absPath }` object. This provides mandatory source mapping for jump-to-definition, code navigation, and AI agent file retrieval. External target nodes are exempt from this requirement.

## Edge Cases

| Scenario | Behavior |
|---|---|
| Nested local packages | Recursively discovered and their targets merged |
| Package with both macro and library targets | Both detected; macro implementations get `macroType: "attached"` |
| Target with custom `path:` | Custom path used instead of default `Sources/<name>` |
| File not belonging to any target | `targetName` is `null` |
| External dependency not in `.build/checkouts` | Indexed fully (not recognized as external) |
| `@Observable` and similar Apple macros | Filtered by built-in attribute list — not tracked as user macros |
| Xcode project without SPM | Falls back to directory-based scanning |
