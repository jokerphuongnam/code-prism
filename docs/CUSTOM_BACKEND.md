# Custom backend guide

Stock languages live under `backends/{js,marlin,…}`.  
You can add **your own** language without forking Prism — implement the [PROTOCOL](./PROTOCOL.md) on top of **core**.

## Quick scaffold (Node)

```bash
cd ~/Documents/Code/code-prism
mkdir -p backends/lua/bin
```

`backends/lua/code-prism-plugin.json`:

```json
{
  "id": "lua",
  "name": "Lua",
  "bin": "lua-prism",
  "extensions": ["lua"],
  "markers": [],
  "version": "0.1.0"
}
```

`backends/lua/index.mjs`:

```js
#!/usr/bin/env node
import { createBackend } from "../../core/src/index.mjs";

const backend = createBackend({
  id: "lua",
  extensions: ["lua"],
  markers: [],
  // Optional: replace default regex extractors
  // extractSignatures(filePath, text, ext) { return { sigs, deps }; },
});

backend.main();
```

`backends/lua/bin/lua-prism`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export CODE_PRISM_LANG="${CODE_PRISM_LANG:-lua}"
export PRISM_EXTS="${PRISM_EXTS:-lua}"
exec node "$DIR/index.mjs" --lang lua "$@"
```

```bash
chmod +x backends/lua/bin/lua-prism backends/lua/index.mjs
prism plugins          # should list Lua
prism detect --root /path/to/lua/project
prism analyze --root /path/to/lua/project --lang lua
```

## Rules

1. **Always** go through `@code-prism/core` (`createBackend`) for Node — do not copy `build-sot.mjs`.
2. Claim only extensions you own; unknown langs without a plugin are **ignored**.
3. Write SoT only under `~/Library/Caches/code-prism/…`.
4. Native backends (Swift, etc.) may skip Node core but must still ship the manifest + CLI contract.

## Install location for private plugins

Instead of committing into this monorepo, you can install a custom backend to:

```text
~/Library/Application Support/CodePrism/backends/lua/
  code-prism-plugin.json
  bin/lua-prism
  …
```

Discovery picks it up the same way as stock langs.
