import crypto from "crypto";
import fs from "fs";
import os from "os";
import path from "path";

export function sanitizeProjectName(name) {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "project";
}

export function projectHash(root) {
  const real = fs.realpathSync(root);
  return crypto.createHash("sha256").update(real).digest("hex").slice(0, 16);
}

export function projectSlug(root) {
  const real = fs.realpathSync(root);
  return `${sanitizeProjectName(path.basename(real))}-${projectHash(real)}`;
}

export function langPrismFolder(lang, cacheFolder) {
  if (cacheFolder) return cacheFolder;
  if (lang === "objc") return "objective-c-prism";
  if (String(lang).endsWith("-prism")) return lang;
  return `${lang}-prism`;
}

export function cacheDir(lang, root, cacheFolder) {
  return path.join(
    os.homedir(),
    "Library",
    "Caches",
    "code-prism",
    projectSlug(root),
    langPrismFolder(lang, cacheFolder)
  );
}
