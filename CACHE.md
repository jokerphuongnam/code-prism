# Code Prism cache (SoT)

Backends **never** write into the user’s project tree.

```text
~/Library/Caches/code-prism/
  <projectName>-<projectHash>/
    swift-prism/
      meta.json
      prism-context.json
      graph.sqlite
    js-prism/
    rust-prism/
    …
```

- `projectName` = basename of the project folder (sanitized)
- `projectHash` = first 16 hex chars of SHA-256(realpath(projectRoot))
- `{lang}-prism` = backend id folder (`swift-prism`, `js-prism`, `objective-c-prism`, …)

## Who does what

| Component | Role |
|-----------|------|
| `*-prism` backends | Read user sources → write under `…/<projectName>-<hash>/{lang}-prism/` |
| **mcp-prism** | `PRISM_CWD` = user project → resolve that cache tree → return data |
| Mac / VS Code UI | Same resolution; Analyze runs all detected `{lang}-prism` backends |
