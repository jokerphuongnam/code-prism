# Code Prism backend protocol

Every language backend — stock or custom — **must** satisfy this contract.
Node backends should be built with `@code-prism/core` (`createBackend`).
Native backends (e.g. Swift) may use another language but still expose the same CLI + manifest + SoT.

## 1. Manifest — `code-prism-plugin.json`

Placed next to the backend entry (discovered under `code-prism/backends/<id>/`):

```json
{
  "id": "lua",
  "name": "Lua",
  "bin": "lua-prism",
  "extensions": ["lua"],
  "markers": [],
  "version": "0.1.0",
  "cacheFolder": "lua-prism"
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `id` | yes | Language id (`js`, `marlin`, …). Cache folder defaults to `{id}-prism`. |
| `name` | yes | Human label |
| `bin` | yes | Executable name under `bin/` |
| `extensions` | yes* | File extensions claimed (no plugin ⇒ language ignored) |
| `markers` | no | Root/project files that boost detect score |
| `cacheFolder` | no | Override (e.g. `objective-c-prism` for `objc`) |
| `version` | no | Semver string |

\*Or non-empty `markers` — see `canDetectLanguage`.

## 2. CLI

```bash
<bin> --root <projectDir> [--out <path/to/prism-context.json>] [--lang <id>]
```

- Exit **0** on success.
- Must **not** write SoT into the user project tree.
- Default SoT location:

```text
~/Library/Caches/code-prism/<projectName>-<hash>/{cacheFolder}/
  prism-context.json
  meta.json
```

## 3. SoT JSON (minimum)

```json
{
  "version": "2.0",
  "generatedAt": "ISO-8601",
  "language": "lua",
  "projectRoot": "/abs/path",
  "files": [
    {
      "path": "/abs/file.lua",
      "target": "app",
      "signatures": [
        { "id": "main", "line": 1, "signature": "…", "dependencies": [] }
      ]
    }
  ],
  "dependencyIndex": {}
}
```

After `prism analyze`, the CLI may **stamp** island/project parents onto this graph.

## 4. Discovery

Scanned on the machine (order):

1. `~/Library/Application Support/CodePrism/backends/<id>/`
2. `~/Documents/Code/code-prism/backends/<id>/` (monorepo)
3. Compat: `…/backends/<id>-prism/` (legacy checkouts)

UI / MCP **never** hardcode language lists — only discovered plugins.
