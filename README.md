# js-prism

Code Prism **language backend** for **js**.

`main` writes SoT only:

```bash
./bin/js-prism --root /path/to/project --out /path/to/project/.codeprism/prism-context.json
```

SoT is read by [mcp-prism](https://github.com/jokerphuongnam/mcp-prism), [code-prism-app-mac](https://github.com/jokerphuongnam/code-prism-app-mac), and [code-prism-vs-code](https://github.com/jokerphuongnam/code-prism-vs-code).

This is a lightweight signature/import map (v0), not a full semantic indexer.
