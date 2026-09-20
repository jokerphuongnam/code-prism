#!/usr/bin/env node
/**
 * Generic lightweight SoT builder (signatures + import-ish edges).
 * Writes Context-v2-compatible prism-context.json under --out or <root>/.codeprism/
 */
import fs from "fs";
import path from "path";

const IGNORE = new Set([
  "node_modules",".git",".build","DerivedData","dist","build",".codeprism",".swiftprism",
  "vendor",".gradle","Pods","coverage",".next",".turbo","__pycache__",".venv"
]);

function parseArgs(argv) {
  let root = process.cwd();
  let out = null;
  let exts = (process.env.PRISM_EXTS || "js,ts,tsx,jsx,kt,kts,marlin").split(",");
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--root") root = path.resolve(argv[++i]);
    else if (argv[i] === "--out") out = path.resolve(argv[++i]);
    else if (argv[i] === "--exts") exts = argv[++i].split(",").map(s => s.trim().replace(/^\./,""));
  }
  return { root, out, exts };
}

function walk(dir, exts, acc=[]) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of entries) {
    if (IGNORE.has(e.name) || e.name.startsWith(".")) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, exts, acc);
    else if (exts.includes(path.extname(e.name).slice(1).toLowerCase())) acc.push(p);
  }
  return acc;
}

function extractSymbols(filePath, text, ext) {
  const lines = text.split(/\r?\n/);
  const sigs = [];
  const deps = new Set();
  const base = path.basename(filePath, path.extname(filePath));
  // file-level node
  sigs.push({ id: base, line: 1, signature: `file ${base}.${ext}`, dependencies: [] });

  const patterns = [
    [/^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z0-9_]+)/, "function"],
    [/^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z0-9_]+)\s*=\s*(?:async\s*)?\(/, "function"],
    [/^\s*(?:export\s+)?class\s+([A-Za-z0-9_]+)/, "class"],
    [/^\s*(?:export\s+)?(?:interface|type)\s+([A-Za-z0-9_]+)/, "type"],
    [/^\s*(?:fun|suspend\s+fun)\s+([A-Za-z0-9_]+)/, "function"],
    [/^\s*(?:class|data\s+class|object|interface)\s+([A-Za-z0-9_]+)/, "type"],
    [/^\s*(?:fn|func|function)\s+([A-Za-z0-9_]+)/, "function"],
    [/^\s*(?:struct|enum|protocol|class)\s+([A-Za-z0-9_]+)/, "type"],
  ];
  const importPatterns = [
    /import\s+.*?from\s+['\"]([^'\"]+)['\"]/,
    /require\(\s*['\"]([^'\"]+)['\"]\s*\)/,
    /import\s+([A-Za-z0-9_.]+)/,
    /#\s*include\s*[<\"]([^>\"]+)[>\"]/,
  ];

  lines.forEach((line, i) => {
    for (const [re, kind] of patterns) {
      const m = line.match(re);
      if (m) {
        const id = `${base}.${m[1]}`;
        sigs.push({ id, line: i + 1, signature: line.trim().slice(0, 160), dependencies: [] });
        break;
      }
    }
    for (const re of importPatterns) {
      const m = line.match(re);
      if (m) deps.add(m[1].split("/").pop().replace(/\.(js|ts|tsx|jsx|kt|marlin)$/, ""));
    }
  });
  // attach file-level deps
  sigs[0].dependencies = [...deps];
  return { sigs, deps: [...deps] };
}

function main() {
  const { root, out, exts } = parseArgs(process.argv);
  const files = walk(root, exts);
  const fileEntries = [];
  const dependencyIndex = {};

  for (const f of files) {
    let text;
    try { text = fs.readFileSync(f, "utf8"); } catch { continue; }
    if (text.includes("\0")) continue;
    const ext = path.extname(f).slice(1).toLowerCase();
    const { sigs, deps } = extractSymbols(f, text, ext);
    const rel = path.relative(root, f);
    fileEntries.push({ path: f, target: "app", signatures: sigs });
    for (const d of deps) {
      (dependencyIndex[d] ||= []).push(sigs[0].id);
    }
    // member deps → file
    for (const s of sigs.slice(1)) {
      (dependencyIndex[s.id] ||= []).push(sigs[0].id);
    }
  }

  const doc = {
    version: "2.0",
    generatedAt: new Date().toISOString(),
    projectType: "generic",
    targets: [{ name: "app", type: "module", dependencies: [], fileCount: fileEntries.length }],
    files: fileEntries,
    dependencyIndex,
    assetMap: [],
    macroMap: [],
  };

  const outPath = out || path.join(root, ".codeprism", "prism-context.json");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  const gi = path.join(path.dirname(outPath), ".gitignore");
  if (!fs.existsSync(gi)) fs.writeFileSync(gi, "*\n");
  fs.writeFileSync(outPath, JSON.stringify(doc, null, 2));
  console.log(JSON.stringify({ _info: `Written ${fileEntries.length} files → ${outPath}` }));
}

main();
