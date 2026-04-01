# Universal Scan Logic — Multi-Target, Macro, and Cross-Module Analysis

SwiftPrism supports three project archetypes: SPM packages (single and multi-target), Xcode projects, and standalone Swift files. This document explains how targets are detected, macros are tracked, cross-module dependencies are linked, and external packages are pruned for token efficiency.

## 1. Multi-Target Detection

### Auto-Detection Flow (`TargetResolver`)

```
Workspace Root
├── Package.swift exists?  → SPM Package mode
│   ├── Parse Package.swift AST for .executableTarget / .target / .testTarget / .macro / .plugin
│   ├── Resolve paths: custom `path:` or default Sources/<name>, Tests/<name>
│   ├── Discover nested Package.swift files → local sub-packages
│   └── Merge all targets
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

Every symbol gets a `targetName` field by checking which target's directory contains its source file. This enables cross-target dependency detection.

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

### AnalysisResult (v2)

```json
{
  "nodes": [...],
  "links": [...],
  "resources": [...],
  "targets": [
    {
      "name": "MyApp",
      "type": "executable",
      "path": "/path/to/Sources/MyApp",
      "dependencies": ["NetworkKit", "DesignSystem"]
    }
  ],
  "macros": [
    {
      "id": "AddInitMacro",
      "name": "AddInitMacro",
      "macroType": "attached",
      "role": "member",
      "conformances": ["MemberMacro"],
      "generatedSymbols": ["MyModel", "UserProfile"],
      "location": { "file": "...", "line": 5, "column": 1 },
      "targetName": "MyMacros"
    }
  ]
}
```

### PrismContext (v2)

The context skeleton now includes:
- `projectType`: `"swift_package"`, `"multi_target_package"`, `"swift_macro_package"`, `"swift_app"`, or `"standalone"`
- `targets[]`: Per-target summary with file count and dependencies
- `macroMap[]`: Macro name, type, role, and list of applied-to symbols

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
