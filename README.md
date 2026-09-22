# Code Prism

Language backends write a **system-cache SoT**; MCP / Mac / VS Code only **read** it. Nothing is written into your project tree.

## Setup (one line)

```bash
curl -fsSL https://raw.githubusercontent.com/jokerphuongnam/code-prism-cli/main/install.sh | bash
```

Installs `prism` + `prism-mcp`, builds [mcp-prism](https://github.com/jokerphuongnam/mcp-prism), and clones **this monorepo** (core + all stock backends).

Requires **Node.js ≥ 20**, `git`, `npm`.

## Quick start

```bash
prism plugins
prism analyze --root /path/to/project
prism-mcp .        # point an MCP client at this
```

## Monorepo layout

```text
core/                 # @code-prism/core — shared SoT builder (createBackend)
backends/
  js/ marlin/ …       # thin adapters from core
  swift/              # native analyzer (same plugin protocol)
docs/
  PROTOCOL.md         # normative CLI + SoT contract
  CUSTOM_BACKEND.md   # how to add your own language
```

Stock languages: `js`, `marlin`, `kotlin`, `rust`, `go`, `cpp`, `objc`, `swift`.

### Custom backends

You are **not** limited to stock langs. Implement the [protocol](./docs/PROTOCOL.md) via [`createBackend`](./docs/CUSTOM_BACKEND.md) (or a native binary with the same CLI + manifest). Drop it under `backends/<id>/` or `~/Library/Application Support/CodePrism/backends/<id>/` — Prism discovers it automatically.

## Other repos

| Repo | Role |
|------|------|
| [code-prism-cli](https://github.com/jokerphuongnam/code-prism-cli) | `prism` / `prism-mcp` + install |
| [mcp-prism](https://github.com/jokerphuongnam/mcp-prism) | MCP over SoT |
| [code-prism-app-mac](https://github.com/jokerphuongnam/code-prism-app-mac) | macOS graph UI |
| [code-prism-vs-code](https://github.com/jokerphuongnam/code-prism-vs-code) | VS Code extension |

Legacy per-lang repos (`js-prism`, `marlin-prism`, …) are **deprecated** — use this monorepo.

## Cache

See [CACHE.md](./CACHE.md). Plugin discovery: [PLUGINS.md](./PLUGINS.md).

```text
~/Library/Caches/code-prism/
  <projectName>-<hash>/
    js-prism/
    marlin-prism/
    …
```
