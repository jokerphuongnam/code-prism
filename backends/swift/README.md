# Swift backend

Swift uses a **native** analyzer (SwiftSyntax), not `@code-prism/core`.

It still must satisfy the same **plugin protocol**:

- `code-prism-plugin.json`
- CLI: `--workspace` / analyze flags (existing analyzer) or install into App Support

## Build

From the archived swift sources (or vendored tree under `.legacy-backends/swift-prism`):

```bash
cd ../../.legacy-backends/swift-prism/core
swift build -c release
```

The `bin/swift-prism-analyzer` shim locates the built binary automatically.
