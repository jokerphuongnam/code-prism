# Backend contract

Each `*-prism` language repo exposes a CLI `main` that writes:

```text
<project>/.codeprism/prism-context.json
<project>/.codeprism/graph.sqlite   # optional, via mcp-prism import
```

UIs and **mcp-prism** only read SoT — they do not embed language parsers.
