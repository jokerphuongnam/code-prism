# Code Prism plugins (backends)

Plugins are **discovered on the machine**, not hardcoded in UI/MCP.

## Locations (scan order)

1. `~/Library/Application Support/CodePrism/backends/<id>/`
   - installed / private custom backends
2. `~/Documents/Code/code-prism/backends/<id>/`
   - **monorepo** stock langs (`js`, `marlin`, `swift`, …)
3. Compat: `~/Documents/Code/code-prism/backends/<id>-prism/`
   - legacy checkouts (deprecated)

Each folder needs `code-prism-plugin.json` + `bin/<bin>`.

## Manifest

See [docs/PROTOCOL.md](./docs/PROTOCOL.md).

## Custom

See [docs/CUSTOM_BACKEND.md](./docs/CUSTOM_BACKEND.md). All Node backends should use `@code-prism/core` (`createBackend`).
