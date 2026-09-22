# SwiftPrism Docker Guide

## How to Run with 1 Click

### Option A: Terminal

```bash
./run.sh
```

This single command:

1. Builds a multi-stage Docker image (Swift 5.10 compiler + Node 20 runtime)
2. Compiles the Swift analyzer into a static release binary inside the container
3. Installs all npm dependencies and builds the React webview
4. Starts the container in the background
5. Extracts the built binary and JS bundles to your local filesystem
6. Verifies the binary is functional

After completion, press **F5** in VS Code to launch the extension.

### Option B: VS Code Task Menu

1. Press **Cmd+Shift+B** (macOS) or **Ctrl+Shift+B** (Linux/Windows)
2. Select **SwiftPrism: Full Build (Docker)**
3. The integrated terminal runs `./run.sh` automatically

### Option C: Dev Container

1. Install the **Dev Containers** extension in VS Code
2. Press **Cmd+Shift+P** → **Dev Containers: Reopen in Container**
3. VS Code reopens inside the Docker environment with everything pre-built
4. The Swift binary, Node runtime, and all dependencies are ready

## How to Reload the Extension

### After Changing Swift Code (core/)

```bash
./run.sh
```

Or use the task: **Cmd+Shift+B** → **SwiftPrism: Build Swift Core Only**

Then reload the Extension Development Host:
- **Cmd+Shift+P** → **Developer: Reload Window**

### After Changing TypeScript / React Code (extension/)

Option 1 — Full rebuild:
```bash
cd extension && npm run build
```

Option 2 — Watch mode (auto-recompile on save):
- **Cmd+Shift+B** → **SwiftPrism: Watch Extension**

Then reload the Extension Development Host:
- **Cmd+Shift+P** → **Developer: Reload Window**

### After Changing React Components (extension/webview/)

```bash
cd extension/webview && npm run build
```

Then reload the Extension Development Host.

## Docker Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Dockerfile                        │
│                                                      │
│  ┌──────────────────────────┐                        │
│  │  Stage 1: swift-builder  │                        │
│  │  swift:5.10-jammy        │                        │
│  │                          │                        │
│  │  swift build -c release  │──▶ swift-prism-analyzer│
│  │  --static-swift-stdlib   │    (static binary)     │
│  └──────────────────────────┘                        │
│                                                      │
│  ┌──────────────────────────┐                        │
│  │  Stage 2: final          │                        │
│  │  node:20-jammy           │                        │
│  │                          │                        │
│  │  COPY binary from Stage1 │                        │
│  │  npm install (host)      │                        │
│  │  npm install (webview)   │                        │
│  │  tsc + vite build        │                        │
│  └──────────────────────────┘                        │
└─────────────────────────────────────────────────────┘
```

### Volume Mounts (docker-compose.yml)

| Host Path | Container Path | Mode | Purpose |
|---|---|---|---|
| `./core/Sources` | `/app/core/Sources` | Read-only | Live Swift source sync |
| `./extension/src` | `/app/extension/src` | Read-only | Live TS source sync |
| `./extension/webview/src` | `/app/extension/webview/src` | Read-only | Live React source sync |

Named volumes (`swift-prism-bin`, `swift-prism-out`, `swift-prism-dist`) persist built artifacts across container restarts.

## Available VS Code Tasks

| Task | Shortcut | Description |
|---|---|---|
| **Full Build (Docker)** | Cmd+Shift+B | Runs `./run.sh` — builds everything via Docker |
| **Build Extension Only** | Task menu | `npm run build` in extension/ |
| **Build Swift Core Only** | Task menu | `swift build` + copy binary |
| **Watch Extension** | Task menu | Auto-recompile TS on save |
| **Docker Up** | Task menu | `docker compose up --build -d` |
| **Docker Down** | Task menu | `docker compose down` |

## Troubleshooting

### Binary architecture mismatch (macOS ARM vs Linux x86)

The Docker container builds a Linux x86_64 binary. If you're on macOS ARM (M1/M2/M3), the extracted binary won't run directly on the host. Two options:

1. Build natively: **Cmd+Shift+B** → **SwiftPrism: Build Swift Core Only**
2. Use the Dev Container: **Cmd+Shift+P** → **Dev Containers: Reopen in Container**

### Container won't start

```bash
docker compose logs
docker compose down --volumes
./run.sh
```

### Extension doesn't load

Verify build outputs exist:

```bash
ls extension/bin/swift-prism-analyzer
ls extension/out/extension.js
ls extension/dist-webview/webview.js
```

If any are missing, run: `./run.sh`
