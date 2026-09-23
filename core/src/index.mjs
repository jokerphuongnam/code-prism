/**
 * @code-prism/core — createBackend(config) for language plugins.
 *
 * Every Node stock backend MUST go through createBackend (no forked SoT builders).
 */
import fs from "fs";
import path from "path";
import { cacheDir, langPrismFolder, projectHash, projectSlug } from "./cache.mjs";
import { parseArgs } from "./cli.mjs";
import { defaultExtractSignatures } from "./extract.mjs";
import { walk } from "./walk.mjs";
import { stampContext } from "./stamp.mjs";

/**
 * @param {object} config
 * @param {string} config.id
 * @param {string[]} config.extensions
 * @param {string[]} [config.markers]
 * @param {string} [config.cacheFolder]
 * @param {(filePath:string,text:string,ext:string)=>{sigs:any[],deps:string[]}} [config.extractSignatures]
 */
export function createBackend(config) {
  if (!config?.id) throw new Error("createBackend: config.id required");
  if (!config.extensions?.length) throw new Error("createBackend: config.extensions required");

  const extract = config.extractSignatures || defaultExtractSignatures;

  function run(argv = process.argv) {
    const { root, out, lang, exts } = parseArgs(argv, {
      lang: config.id,
      extensions: config.extensions,
    });
    if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
      console.error(`error: root is not a directory: ${root}`);
      process.exit(2);
    }
    const realRoot = fs.realpathSync(root);
    const slug = projectSlug(realRoot);
    const destDir = out
      ? path.dirname(out)
      : cacheDir(lang, realRoot, config.cacheFolder);
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
      const { sigs, deps } = extract(f, text, ext);
      fileEntries.push({ path: f, target: "app", signatures: sigs });
      for (const d of deps) (dependencyIndex[d] ||= []).push(sigs[0].id);
      for (const s of sigs.slice(1)) (dependencyIndex[s.id] ||= []).push(sigs[0].id);
    }

    const doc = {
      version: "2.0",
      generatedAt: new Date().toISOString(),
      projectType: "generic",
      language: lang,
      projectRoot: realRoot,
      projectSlug: slug,
      projectKey: projectHash(realRoot),
      targets: [
        { name: "app", type: "module", dependencies: [], fileCount: fileEntries.length },
      ],
      files: fileEntries,
      dependencyIndex,
      assetMap: [],
      macroMap: [],
    };
    fs.writeFileSync(outPath, JSON.stringify(doc));
    stampContext(outPath, realRoot);
    const meta = {
      projectRoot: realRoot,
      language: lang,
      projectSlug: slug,
      projectKey: projectHash(realRoot),
      generatedAt: doc.generatedAt,
      fileCount: fileEntries.length,
      sot: { json: outPath, sqlite: path.join(path.dirname(outPath), "graph.sqlite") },
    };
    fs.writeFileSync(
      path.join(path.dirname(outPath), "meta.json"),
      JSON.stringify(meta, null, 2)
    );
    console.log(
      JSON.stringify({
        _info: `SoT cached (${slug}/${langPrismFolder(lang, config.cacheFolder)}): ${fileEntries.length} files`,
        cacheDir: path.dirname(outPath),
        json: outPath,
        projectRoot: realRoot,
      })
    );
  }

  return {
    config: {
      id: config.id,
      extensions: config.extensions,
      markers: config.markers || [],
      cacheFolder: config.cacheFolder || null,
    },
    run,
    /** Entry for bin scripts: node index.mjs … */
    main() {
      run(process.argv);
    },
  };
}

export { defaultExtractSignatures, walk, parseArgs, cacheDir, projectSlug };
