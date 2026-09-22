import fs from "fs";
import path from "path";

export const IGNORE = new Set([
  "node_modules", ".git", ".build", "DerivedData", "dist", "build",
  ".codeprism", ".swiftprism", "vendor", ".gradle", "Pods", "coverage",
  ".next", ".turbo", "__pycache__", ".venv", "target", ".cache",
  "CMakeFiles", "Generated", "generated",
]);

export function walk(dir, exts, acc = []) {
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
