import path from "path";

/** Default multi-lang regex extractors — backends may override. */
export function defaultExtractSignatures(filePath, text, ext) {
  const lines = text.split(/\r?\n/);
  const sigs = [];
  const deps = new Set();
  const base = path.basename(filePath, path.extname(filePath));
  sigs.push({ id: base, line: 1, signature: `file ${base}.${ext}`, dependencies: [] });
  const patterns = [
    [/^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z0-9_]+)/, "function"],
    [/^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z0-9_]+)\s*=\s*(?:async\s*)?\(/, "function"],
    [/^\s*(?:export\s+)?class\s+([A-Za-z0-9_]+)/, "class"],
    [/^\s*(?:export\s+)?(?:interface|type)\s+([A-Za-z0-9_]+)/, "type"],
    [/^\s*(?:fun|suspend\s+fun)\s+([A-Za-z0-9_]+)/, "function"],
    [/^\s*(?:class|data\s+class|object|interface)\s+([A-Za-z0-9_]+)/, "type"],
    [/^\s*(?:fn|func|function)\s+([A-Za-z0-9_]+)/, "function"],
    [/^\s*(?:pub\s+)?(?:fn|struct|enum|trait|impl)\s+([A-Za-z0-9_]+)/, "type"],
    [/^\s*(?:type|struct|interface)\s+([A-Za-z0-9_]+)/, "type"],
    [/^\s*(?:class|struct)\s+([A-Za-z0-9_]+)\b/, "type"],
    [/^\s*[-+]\s*\([^)]*\)\s*([A-Za-z0-9_]+)/, "function"],
  ];
  const importPatterns = [
    /import\s+.*?from\s+['"]([^'"]+)['"]/,
    /require\(\s*['"]([^'"]+)['"]\s*\)/,
    /import\s+([A-Za-z0-9_./"-]+)/,
    /^\s*use\s+([A-Za-z0-9_:]+)/,
    /#\s*include\s*[<"]([^>"]+)[>"]/,
  ];
  lines.forEach((line, i) => {
    for (const [re] of patterns) {
      const m = line.match(re);
      if (m) {
        sigs.push({
          id: `${base}.${m[1]}`,
          line: i + 1,
          signature: line.trim().slice(0, 160),
          dependencies: [],
        });
        break;
      }
    }
    for (const re of importPatterns) {
      const m = line.match(re);
      if (m) {
        const raw = m[1].replace(/['"]/g, "");
        deps.add(
          raw
            .split("/")
            .pop()
            .replace(/\.(js|ts|tsx|jsx|kt|marlin|rs|go|m|mm|h|hpp|cpp|lua)$/, "")
        );
      }
    }
  });
  sigs[0].dependencies = [...deps];
  return { sigs, deps: [...deps] };
}
