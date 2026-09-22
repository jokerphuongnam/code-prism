import path from "path";

export function parseArgs(argv, defaults = {}) {
  let root = process.cwd();
  let out = null;
  let lang = process.env.CODE_PRISM_LANG || process.env.PRISM_LANG || defaults.lang || "js";
  let exts = (
    process.env.PRISM_EXTS ||
    (defaults.extensions || ["js"]).join(",")
  )
    .split(",")
    .map((s) => s.trim().replace(/^\./, ""))
    .filter(Boolean);
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--root") root = path.resolve(argv[++i]);
    else if (argv[i] === "--out") out = path.resolve(argv[++i]);
    else if (argv[i] === "--lang") lang = argv[++i];
    else if (argv[i] === "--exts")
      exts = argv[++i].split(",").map((s) => s.trim().replace(/^\./, ""));
  }
  return { root, out, lang, exts };
}
