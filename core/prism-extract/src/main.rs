use rayon::prelude::*;
use serde_json::{json, Value};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::exit;

const SKIP: &[&str] = &[
    ".build", "DerivedData", "Pods", "node_modules", ".git", "target", "dist",
    "build", "Carthage", ".swiftpm",
];

fn main() {
    let mut root = None;
    let mut out = None;
    let mut lang = env::var("CODE_PRISM_LANG").unwrap_or_else(|_| "generic".into());
    let mut exts = env::var("PRISM_EXTS").unwrap_or_default();
    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--root" => { i += 1; root = args.get(i).cloned(); }
            "--out" => { i += 1; out = args.get(i).cloned(); }
            "--lang" => { i += 1; if let Some(v) = args.get(i) { lang = v.clone(); } }
            "--exts" => { i += 1; if let Some(v) = args.get(i) { exts = v.clone(); } }
            _ => {}
        }
        i += 1;
    }
    let Some(root) = root else {
        eprintln!("error: --root required");
        exit(2);
    };
    let Some(out) = out else {
        eprintln!("error: --out required");
        exit(2);
    };
    let extensions: Vec<String> = exts.split(',').map(|s| s.trim().trim_start_matches('.').to_string()).filter(|s| !s.is_empty()).collect();
    if extensions.is_empty() {
        eprintln!("error: PRISM_EXTS or --exts required");
        exit(2);
    }
    let files = walk(Path::new(&root), &extensions);
    let entries: Vec<Value> = files.par_iter().filter_map(|path| extract(path)).collect();
    let doc = json!({
        "version": "2.0",
        "language": lang,
        "projectRoot": fs::canonicalize(&root).unwrap_or(PathBuf::from(&root)),
        "files": entries
    });
    if let Some(parent) = Path::new(&out).parent() {
        let _ = fs::create_dir_all(parent);
    }
    fs::write(&out, serde_json::to_vec(&doc).unwrap()).unwrap();
    println!("{{\"_info\":\"SoT cached ({lang}): {} files\",\"json\":\"{out}\"}}", entries.len());
}

fn walk(dir: &Path, exts: &[String]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(current) = stack.pop() {
        let entries = match fs::read_dir(&current) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.') || SKIP.iter().any(|s| *s == name) { continue; }
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                if exts.iter().any(|x| x == ext) {
                    out.push(path);
                }
            }
        }
    }
    out
}

fn extract(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    if text.contains('\0') { return None; }
    let base = path.file_stem()?.to_string_lossy().to_string();
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
    let mut sigs = vec![json!({"id": base, "line": 1, "signature": format!("file {base}.{ext}"), "dependencies": []})];
    let mut deps = Vec::new();
    for (i, line) in text.lines().enumerate() {
        if let Some(name) = decl_name(line) {
            let trimmed = line.trim();
            let signature: String = trimmed.chars().take(160).collect();
            sigs.push(json!({"id": format!("{base}.{name}"), "line": i + 1, "signature": signature, "dependencies": []}));
        }
        if let Some(dep) = import_name(line) {
            deps.push(dep);
        }
    }
    sigs[0]["dependencies"] = json!(deps);
    Some(json!({"path": path, "target": "app", "signatures": sigs}))
}

fn decl_name(line: &str) -> Option<String> {
    let t = line.trim_start();
    for prefix in [
        "export async function ", "export function ", "async function ", "function ",
        "export class ", "class ", "export interface ", "export type ", "interface ", "type ",
        "pub fn ", "pub struct ", "pub enum ", "pub trait ", "fn ", "struct ", "enum ", "trait ",
        "fun ", "suspend fun ", "data class ", "object ",
    ] {
        if let Some(rest) = t.strip_prefix(prefix) {
            return ident(rest);
        }
    }
    None
}

fn ident(rest: &str) -> Option<String> {
    let name: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
    if name.is_empty() { None } else { Some(name) }
}

fn import_name(line: &str) -> Option<String> {
    let t = line.trim();
    let raw = if let Some(i) = t.find("from \"") {
        t[i + 6..].split('"').next()?
    } else if let Some(i) = t.find("from '") {
        t[i + 6..].split('\'').next()?
    } else if let Some(rest) = t.strip_prefix("use ") {
        rest.split(|c: char| c == ' ' || c == ';' || c == '{').next()?
    } else if t.contains("#include") {
        let bytes = t.as_bytes();
        let start = bytes.iter().position(|c| *c == b'<' || *c == b'"')? + 1;
        let end = bytes[start..].iter().position(|c| *c == b'>' || *c == b'"')? + start;
        return Some(stem(&t[start..end]));
    } else {
        return None;
    };
    let name = stem(raw);
    if name.len() < 2 || !name.chars().next().unwrap_or('_').is_ascii_alphabetic() { return None; }
    Some(name)
}

fn stem(raw: &str) -> String {
    let base = raw.rsplit(['/', '\\']).next().unwrap_or(raw);
    let base = base.split('.').next().unwrap_or(base);
    base.split("::").last().unwrap_or(base).to_string()
}
