# Git Policy

## What Is Tracked

### VS Code Workspace Files

| File | Tracked | Reason |
|---|---|---|
| `.vscode/launch.json` | Yes | F5 debug configurations must be identical for all contributors |
| `.vscode/tasks.json` | Yes | Cmd+Shift+B build tasks must be consistent |
| `.vscode/extensions.json` | Yes | Recommended extensions ensure the same tooling |
| `.vscode/settings.json` | No | Contains personal preferences (font size, theme, local binary paths) that vary per machine |

### AI Agent Configuration Files

| File | Tracked | Reason |
|---|---|---|
| `.cursorrules` | Yes | Ensures every Cursor user gets the same instruction set for code generation |
| `.clauderules` | Yes | Ensures every Claude Code user gets the same behavioral directives |
| `CLAUDE.md` | Yes | Project-level memory and conventions for Claude Code agents |
| `.claude/settings.json` | Yes | Shared permission and tool configuration for Claude Code sessions |

AI agent configs are tracked because they define **how the agent understands the project**. If one developer's agent knows to read `prism-context.json` before modifying Swift files but another's doesn't, the quality of AI-assisted changes diverges. These files are effectively part of the project's developer experience contract.

### Generated Artifacts

| File | Tracked | Reason |
|---|---|---|
| `prism-context.json` | No | Rebuilt on every `./run.sh` or "Analyze Project" — contains absolute paths specific to the local machine |
| `extension/bin/swift-prism-analyzer` | No | Binary artifact — must be built locally or via Docker for the correct architecture (ARM vs x86) |
| `extension/out/` | No | TypeScript compilation output — rebuilt by `tsc` |
| `extension/dist-webview/` | No | Vite bundle output — rebuilt by `vite build` |
| `core/.build/` | No | SPM build cache — rebuilt by `swift build` |

### Package Lock Files

| File | Tracked | Reason |
|---|---|---|
| `core/Package.resolved` | Yes | Pins exact Swift dependency versions for reproducible builds |
| `extension/package-lock.json` | Yes | Pins exact npm dependency versions |
| `extension/webview/package-lock.json` | Yes | Pins exact webview npm dependency versions |

## Line Ending Policy

All text files are normalized to LF via `.gitattributes`. This prevents mixed-ending diffs when contributors switch between macOS and Windows. Binary files (images, the Swift binary) are marked explicitly to avoid accidental normalization.

## Security

The following patterns are globally ignored to prevent accidental credential commits:

- `.env` and `.env.*` (environment variables with API keys, tokens)
- `secrets.*` (any file prefixed with "secrets")
- `*.pem`, `*.key`, `*.p12`, `*.cer` (cryptographic material)

The `.env.example` pattern is excluded from the ignore rule so teams can commit template environment files.

## Branching Convention

| Branch | Purpose |
|---|---|
| `main` | Stable, release-ready code |
| `develop` | Integration branch for features |
| `feature/<name>` | Individual feature work |
| `fix/<name>` | Bug fixes |
| `docs/<name>` | Documentation changes |
