# Code Prism plugins (backends)

Plugins are **discovered on the machine**, not hardcoded in UI/MCP.

## Locations (scan order)

1. `~/Library/Application Support/CodePrism/backends/<id>/`
   - installed binary + optional `code-prism-plugin.json`
2. `~/Documents/Code/code-prism/backends/*-prism/`
   - each checkout is a plugin repo with `code-prism-plugin.json` + `bin/…`

## Manifest (`code-prism-plugin.json`)

```json
{
  "id": "js",
  "name": "JS/TS",
  "bin": "js-prism",
  "extensions": ["js", "ts", "tsx"],
  "markers": ["package.json", "tsconfig.json"],
  "version": "0.1.0"
}
```

- Folder under project cache is always `{id}-prism` except `objc` → `objective-c-prism` (or set `"cacheFolder"` later).
- Language detect = union of all discovered plugins’ `extensions` + `markers`.
- If no plugin is installed/checked out → UI reports error (cannot detect languages).
