#!/usr/bin/env node
/**
 * Generic lightweight SoT builder.
 * Writes to ~/Library/Caches/code-prism/<lang>/<projectKey>/  (NOT into the user project).
 */
import crypto from "crypto";
import fs from "fs";
import os from "os";
import path from "path";

const IGNORE = new Set([
  "node_modules", ".git", ".build", "DerivedData", "dist", "build",
  ".codeprism", ".swiftprism", "vendor", ".gradle", "Pods", "coverage",
  ".next", ".turbo", "__pycache__", ".venv", "target",
]);

function parseArgs(argv) {
  let root = process.cwd();
  let out = null; // if set, write exactly there (advanced); default = cache
  let lang = process.env.CODE_PRISM_LANG || process.env.PRISM_LANG || "js";
  let exts = (process.env.PRISM_EXTS || "js,ts,tsx,jsx,mjs,cjs").split(",");
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--root") root = path.resolve(argv[++i]);
    else if (argv[i] === "--out") out = path.resolve(argv[++i]);
    else if (argv[i] === "--lang") lang = argv[++i];
    else if (argv[i] === "--exts") exts = argv[++i].split(",").map((s) => s.trim().replace(/^\./, ""));
  }
  return { root, out, lang, exts };
}

function projectKey(root) {
  const real = fs.realpathSync(root);
  return crypto.createHash("sha256").update(real).digest("hex").slice(0, 16);
}

function cacheDir(lang, key) {
  return path.join(os.homedir(), "Library", "Caches", "code-prism", lang, key);
}

function walk(dir, exts, acc = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
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
    [/^\s*func\s+\(?.*?\)?\s*([A-Za-z0-9_]+)/, "function"],
    [/^\s*(?:type|struct|interface)\s+([A-Za-z0-9_]+)/, "type"],
    [/^\s*(?:class|struct)\s+([A-Za-z0-9_]+)\b/, "type"],
    [/^\s*[-+]\s*\([^)]*\)\s*([A-Za-z0-9_]+)/, "function"],
  ];
  const importPatterns = [
    /import\s+.*?from\s+['\"]([^'\"]+)['\"]/,
    /require\(\s*['\"]([^'\"]+)['\"]\s*\)/,
    /import\s+([A-Za-z0-9_./\"-]+)/,
    /^\s*use\s+([A-Za-z0-9_:]+)/,
  ];

  lines.forEach((line, i) => {
    for (const [re] of patterns) {
      const m = line.match(re);
      if (m) {
        const id = `${base}.${m[1]}`;
        sigs.push({ id, line: i + 1, signature: line.trim().slice(0, 160), dependencies: [] });
        break;
      }
    }
    for (const re of importPatterns) {
      const m = line.match(re);
      if (m) {
        const raw = m[1].replace(/['\"]/g, "");
        deps.add(raw.split("/").pop().replace(/\.(js|ts|tsx|jsx|kt|marlin|rs|go)$/, ""));
      }
    }
  });
  sigs[0].dependencies = [...deps];
  return { sigs, deps: [...deps] };
}

function main() {
  const { root, out, lang, exts } = parseArgs(process.argv);
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    console.error(`error: root is not a directory: ${root}`);
    process.exit(2);
  }

  const key = projectKey(root);
  const destDir = out ? path.dirname(out) : cacheDir(lang, key);
  const outPath = out || path.join(destDir, "prism-context.json");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });

  const files = walk(root, exts);
  const fileEntries = [];
  const dependencyIndex = {};

  for (const f of files) {
    let text;
    try {
      text = fs.readFileSync(f, "utf8");
    } catch {
      continue;
    }
    if (text.includes("\0")) continue;
    const ext = path.extname(f).slice(1).toLowerCase();
    const { sigs, deps } = extractSymbols(f, text, ext);
    fileEntries.push({ path: f, target: "app", signatures: sigs });
    for (const d of deps) {
      (dependencyIndex[d] ||= []).push(sigs[0].id);
    }
    for (const s of sigs.slice(1)) {
      (dependencyIndex[s.id] ||= []).push(sigs[0].id);
    }
  }

  const realRoot = fs.realpathSync(root);
  const doc = {
    version: "2.0",
    generatedAt: new Date().toISOString(),
    projectType: "generic",
    language: lang,
    projectRoot: realRoot,
    projectKey: key,
    targets: [{ name: "app", type: "module", dependencies: [], fileCount: fileEntries.length }],
    files: fileEntries,
    dependencyIndex,
    assetMap: [],
    macroMap: [],
  };

  fs.writeFileSync(outPath, JSON.stringify(doc, null, 2));
  const meta = {
    projectRoot: realRoot,
    language: lang,
    projectKey: key,
    generatedAt: doc.generatedAt,
    fileCount: fileEntries.length,
    sot: { json: outPath, sqlite: path.join(path.dirname(outPath), "graph.sqlite") },
  };
  fs.writeFileSync(path.join(path.dirname(outPath), "meta.json"), JSON.stringify(meta, null, 2));

  console.log(
    JSON.stringify({
      _info: `SoT cached (${lang}/${key}): ${fileEntries.length} files`,
      cacheDir: path.dirname(outPath),
      json: outPath,
      projectRoot: realRoot,
    })
  );
}

main();
