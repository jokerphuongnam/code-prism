# Code Prism

Language backends write a **system-cache SoT**; MCP / Mac / VS Code only **read** it. Nothing is written into your project tree.

## Setup (one line)

```bash
curl -fsSL https://raw.githubusercontent.com/jokerphuongnam/code-prism-cli/main/install.sh | bash
```

That installs:

- **`prism`** / **`prism-mcp`** → `~/bin`
- **[mcp-prism](https://github.com/jokerphuongnam/mcp-prism)** (built)
- language backends under `~/Documents/Code/code-prism/backends/`

Requires **Node.js ≥ 20**, `git`, `npm`.

## Quick start

```bash
prism plugins
prism analyze --root /path/to/project
prism-mcp .        # point an MCP client at this
```

MCP client:

```json
{
  "mcpServers": {
    "code-prism": {
      "command": "prism-mcp",
      "args": ["."]
    }
  }
}
```

## Repos

| Repo | Role |
|------|------|
| [code-prism-cli](https://github.com/jokerphuongnam/code-prism-cli) | `prism` + `prism-mcp` + install script |
| [mcp-prism](https://github.com/jokerphuongnam/mcp-prism) | MCP server over SoT cache |
| [code-prism-app-mac](https://github.com/jokerphuongnam/code-prism-app-mac) | macOS graph viewer |
| [code-prism-vs-code](https://github.com/jokerphuongnam/code-prism-vs-code) | VS Code extension |
| `*-prism` backends | `js`, `marlin`, `kotlin`, `rust`, `go`, `cpp`, `objective-c`, `swift` |

## Cache layout

See [CACHE.md](./CACHE.md). Plugins discovery: [PLUGINS.md](./PLUGINS.md).

```text
~/Library/Caches/code-prism/
  <projectName>-<hash>/
    js-prism/
    marlin-prism/
    …
```
