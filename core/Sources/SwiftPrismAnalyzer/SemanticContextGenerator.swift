import Foundation
import SwiftSyntax

// ═══════════════════════════════════════════════════════════════════════════════
// SemanticContextGenerator — Entity-Aware Local LLM Pre-Processing
//
// Two-pass enrichment pipeline:
//   Pass 1: Leaf nodes (functions, macros, entry_points, targets)
//   Pass 2: Parent nodes (classes, structs, enums, actors, protocols)
//           — incorporates children's resolved contexts
//
// Flavor-specific token templates:
//   Function:  f:name|i:intent|p:params|d:deps|s:side_effects
//   Class:     c:name|resp:responsibility|state:fields|d:deps
//   Struct:    s:name|p:fields|i:data_purpose
//   Protocol:  i:name|contract:behaviors|req:methods
//   Enum:      e:name|cases:a,b,c|i:purpose
//   Target:    lib:name|role:project_role|usage:features
// ═══════════════════════════════════════════════════════════════════════════════

// MARK: - Cache Types

struct SemanticCacheEntry: Codable {
    let hash: String
    let context: String
    let generatedAt: String
}

struct SemanticCache: Codable {
    var version: String = "2.0"
    var entries: [String: SemanticCacheEntry] = [:]
}

// MARK: - Source Extractor

struct SourceExtractor {
    let fileSources: [(path: String, tree: SourceFileSyntax)]
    private let treeByPath: [String: SourceFileSyntax]

    init(fileSources: [(path: String, tree: SourceFileSyntax)]) {
        self.fileSources = fileSources
        self.treeByPath = Dictionary(fileSources.map { ($0.path, $0.tree) }, uniquingKeysWith: { a, _ in a })
    }

    /// Extract the full source body starting at `line`. Uses brace-depth counting.
    /// Scans up to 300 lines to capture complete class/function bodies.
    func extract(filePath: String, line: Int, maxLines: Int = 300) -> String? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        let startIdx = max(0, line - 1)
        guard startIdx < lines.count else { return nil }

        var depth = 0
        var foundOpen = false
        var endIdx = startIdx
        var complete = false

        for i in startIdx..<min(lines.count, startIdx + maxLines) {
            for ch in lines[i] {
                if ch == "{" { depth += 1; foundOpen = true }
                if ch == "}" { depth -= 1 }
            }
            endIdx = i
            if foundOpen && depth <= 0 { complete = true; break }
        }

        let source = lines[startIdx...endIdx].joined(separator: "\n")
        if !complete && foundOpen {
            return source + "\n// ... truncated (\(depth) open braces remaining)"
        }
        return source
    }
}

// MARK: - Content Hashing

func sha256Hash(_ input: String) -> String {
    let data = Data(input.utf8)
    var hash: UInt64 = 14695981039346656037
    for byte in data {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    hash ^= UInt64(data.count)
    hash = hash &* 1099511628211
    return String(format: "%016llx", hash)
}

// MARK: - Flavor-Specific LLM Prompts

/// UDLF+ Hardcore prompt — full source body injected as user prompt.
private let USP_SYSTEM_PROMPT = """
Distill this Swift code into a machine-to-machine logic flow.
Symbols: ->(flow) ?(cond) !(force) @(state change) tr(trigger/call) m:(modify) src:(source)
         g:(guard) ~>(propagation) snk:(sink) err:(error) sync:(thread) cost:L/H ⚠(risk)
Focus on: Logic constraints (guard/if, min/max), Animation triggers, Side-effects.
NO natural language. 1 line only.

Type: t:c t:s t:e t:p t:a t:tg  Exec: f i di g st ws ds

Examples:
  f|g:intensity!=nil!->m:blur.val->tr:layoutRefresh!$V|@UI|sync:main|cost:L
  e:ds|r:val->tr:setupBlur!|@UI
  e:ws|g:old!=new!->tr:validate->@pending~>delegate
  e:g|src:self.first,last->$S|cost:L
  t:c|i:ConnMgr|ini:socket!->@idle|di:kill!->@closed|sync:bg|err:retry
  t:a|i:DataSync|src:API->snk:cache|sync:actor|cost:H
  f|g:auth?valid!->tr:API.fetch->err:throw|sync:bg|cost:H

Output: 1 line. Symbolic only.

"""

private func buildLLMPrompt(sourceCode: String, childContexts: [String]) -> String {
    var prompt = USP_SYSTEM_PROMPT + sourceCode
    if !childContexts.isEmpty {
        prompt += "\n\n// Members context:\n// " + childContexts.prefix(6).joined(separator: "\n// ")
    }
    return prompt
}

private func buildLibraryPrompt(entry: FlatMapEntry, callerNames: [String]) -> String {
    var meta = USP_SYSTEM_PROMPT + "Library: \(entry.name)"
    if let origin = entry.origin, !origin.isEmpty { meta += "\nOrigin: \(origin)" }
    if !callerNames.isEmpty { meta += "\nUsed by: \(callerNames.prefix(8).joined(separator: ", "))" }
    return meta
}

// MARK: - Local LLM Bridge

func queryLocalLLM(sourceCode: String, model: String = "mistral", timeoutSeconds: Double = 30) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ollama", "run", model, sourceCode]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    let deadline = DispatchTime.now() + .seconds(Int(timeoutSeconds))
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        group.leave()
    }

    let result = group.wait(timeout: deadline)
    if result == .timedOut {
        process.terminate()
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !output.isEmpty else { return nil }

    // Take first line only, cap at 150 chars
    let firstLine = output.components(separatedBy: "\n").first ?? output
    return firstLine.count > 150 ? String(firstLine.prefix(150)) : firstLine
}

// MARK: - Structural Fallback — Entity-Specific

private let objectFlavors: Set<String> = ["class", "struct", "enum", "actor", "protocol"]

/// Universal Semantic Protocol fallback — unified t:|i:|d:|s:|p:|r: tags for all flavors.
func generateStructuralContext(
    node: FlatMapEntry,
    sourceCode: String?,
    childContexts: [String] = [],
    callerNames: [String] = [],
    extensionCount: Int = 0
) -> String {
    var parts: [String] = []

    // Determine t: (type) or e: (executable) tag
    let execTag = inferExecTag(node)
    if let exec = execTag {
        parts.append("e:\(exec)")
    } else {
        let typeCodes: [String: String] = [
            "class": "c", "struct": "s", "enum": "e", "actor": "a", "protocol": "p",
            "macro": "m", "target": "tg",
        ]
        parts.append("t:\(typeCodes[node.flavor] ?? node.flavor)")
    }

    // i: — intent
    if node.flavor == "target" {
        if node.origin == nil || node.origin?.isEmpty == true { parts.append("i:internal_module") }
        else if node.origin == "Apple" { parts.append("i:\(inferAppleRole(node.name))") }
        else { parts.append("i:third_party") }
    } else if objectFlavors.contains(node.flavor) {
        if !childContexts.isEmpty {
            let intents = extractTokens(from: childContexts, prefix: "i:")
            if !intents.isEmpty { parts.append("i:\(intents.prefix(3).joined(separator: ","))") }
        } else if let purpose = inferStructPurpose(node.name) ?? inferEnumPurpose(node.name) {
            parts.append("i:\(purpose)")
        }
    } else {
        // Executables — special-case accessors and lifecycle, then fall through to name inference
        let lowName = node.name.lowercased()
        if lowName == "willset" || lowName.hasSuffix(".willset") { parts.append("i:validate_before_set") }
        else if lowName == "didset" || lowName.hasSuffix(".didset") { parts.append("i:react_after_set") }
        else if lowName == "deinit" { parts.append("i:cleanup") }
        else if node.flavor == "initializer" || lowName == "init" || lowName.hasPrefix("init(") { parts.append("i:initialize") }
        else if let intent = inferFunctionIntent(node.name) { parts.append("i:\(intent)") }
    }

    // p: — params/properties/cases
    if let params = node.parameterTypes, !params.isEmpty {
        parts.append("p:\(params.prefix(4).joined(separator: ","))")
    } else if node.flavor == "enum" && !childContexts.isEmpty {
        let names = childContexts.prefix(5).compactMap { ctx -> String? in
            guard let range = ctx.range(of: #"i:(\w+)"#, options: .regularExpression) else { return nil }
            return String(ctx[range]).split(separator: ":").last.map(String.init)
        }
        if !names.isEmpty { parts.append("p:\(names.joined(separator: ","))") }
    } else if let stores = node.stores, !stores.isEmpty {
        parts.append("p:\(stores.prefix(5).map(leafName).joined(separator: ","))")
    }

    // Behavioral deps: r: (read), m: (modify), tr: (trigger), d: (structural)
    var structural: [String] = []
    if let ext = node.extends { structural.append(leafName(ext)) }
    if let impls = node.implements { structural.append(contentsOf: impls.prefix(3).map(leafName)) }
    if !structural.isEmpty { parts.append("d:\(structural.joined(separator: ","))") }

    var triggers: [String] = []
    if let calls = node.calls { triggers.append(contentsOf: calls.prefix(4).map(leafName)) }
    if node.flavor == "target" && !callerNames.isEmpty { triggers.append(contentsOf: callerNames.prefix(4)) }
    if !triggers.isEmpty { parts.append("tr:\(triggers.joined(separator: ","))") }

    if let stores = node.stores, !stores.isEmpty, objectFlavors.contains(node.flavor) {
        parts.append("r:\(stores.prefix(3).map(leafName).joined(separator: ","))")
    }

    // ret: — returns/requirements
    if let returns = node.returnTypes, !returns.isEmpty {
        parts.append("ret:\(returns.prefix(3).joined(separator: ","))")
    } else if node.flavor == "protocol" && !childContexts.isEmpty {
        let methods = childContexts.prefix(4).compactMap { ctx -> String? in
            guard let range = ctx.range(of: #"i:(\w+)"#, options: .regularExpression) else { return nil }
            return String(ctx[range]).split(separator: ":").last.map(String.init)
        }
        if !methods.isEmpty { parts.append("ret:\(methods.joined(separator: ","))") }
    }

    // Object-only: unified lifecycle + accessor + extension with UDLF flow
    if objectFlavors.contains(node.flavor) {
        let lifecycle = analyzeLifecycle(node, sourceCode)
        if let ini = lifecycle.ini {
            let hasLogic = ini.contains("triggers_logic") || ini.contains("conn_remote") || ini.contains("add_observers")
            let clean = ini.replacingOccurrences(of: "assign_only", with: "assign").replacingOccurrences(of: "triggers_logic,", with: "").replacingOccurrences(of: "triggers_logic", with: "")
            parts.append("ini:\(clean.isEmpty ? "assign" : clean)\(hasLogic ? "!->@st:ready" : "")")
        }
        if let di = lifecycle.di { parts.append("di:\(di)!->@st:closed") }

        let accSummary = summarizeAccessors(childContexts)
        if let acc = accSummary { parts.append("acc:\(acc)") }

        if extensionCount > 0, let cap = inferExtensionCapabilities(sourceCode) {
            parts.append("ext:\(cap)")
        }
    }

    // Intelligence annotations
    if let src = sourceCode {
        // err: — error handling
        if src.contains("catch") && src.contains("retry") { parts.append("err:retry") }
        else if src.contains("throw") { parts.append("err:throw") }
        else if src.contains("try?") { parts.append("err:silent") }

        // sync: — concurrency
        if node.flavor == "actor" { parts.append("sync:actor") }
        else if src.contains("DispatchQueue.main") || src.contains("@MainActor") { parts.append("sync:main") }
        else if src.contains("DispatchQueue.global") || src.contains(".background") { parts.append("sync:bg") }
        else if src.contains("async ") || src.contains("await ") || src.contains("Task {") { parts.append("sync:async") }

        // cost: — computational cost
        if src.contains("for ") && src.range(of: #"for\s.*in\s.*for\s.*in"#, options: .regularExpression) != nil { parts.append("cost:H") }
        else { parts.append("cost:L") }

        // p: — design pattern
        if src.contains(".shared") || src.contains("static let") && src.contains("()") { parts.append("p:singleton") }
        else if src.contains("delegate?.") || src.contains("Delegate") { parts.append("p:delegate") }
        else if src.contains("NotificationCenter") || src.contains("@Published") || src.contains(".sink") { parts.append("p:observer") }

        // @ state effects
        var effects: [String] = []
        if src.contains("URLSession") || src.contains("URLRequest") { effects.append("net") }
        if src.contains("FileManager") { effects.append("disk") }
        if src.contains("UserDefaults") || src.contains("CoreData") { effects.append("state") }
        if src.contains("UIView") || src.contains("SwiftUI") { effects.append("ui") }
        if !effects.isEmpty { parts.append("@\(effects.joined(separator: ","))") }

        // ⚠ risk: UI update from background
        if (src.contains("DispatchQueue.global") || src.contains(".background")) &&
           (src.contains("UILabel") || src.contains(".text =") || src.contains("UIView")) {
            parts.append("⚠:ui_off_main")
        }
    } else if node.flavor == "actor" {
        parts.append("sync:actor")
        parts.append("cost:L")
    }

    // hub/leaf classification
    let callCount = (node.calls?.count ?? 0) + (node.inits?.count ?? 0)
    if callCount >= 8 { parts.append("hub") }
    else if callCount == 0 && (node.stores?.isEmpty ?? true) { parts.append("leaf") }

    return parts.joined(separator: "|")
}

// MARK: - Helpers

private func leafName(_ id: String) -> String {
    id.split(separator: ":").last.map(String.init) ?? id
}

private func extractTokens(from contexts: [String], prefix: String) -> [String] {
    var results: [String] = []
    var seen = Set<String>()
    for ctx in contexts {
        for segment in ctx.split(separator: "|") {
            let s = String(segment)
            if s.hasPrefix(prefix) {
                let val = String(s.dropFirst(prefix.count))
                if !val.isEmpty && seen.insert(val).inserted { results.append(val) }
            }
        }
    }
    return results
}

private func inferFunctionIntent(_ name: String) -> String? {
    let n = name.lowercased()
    if n.hasPrefix("get") || n.hasPrefix("fetch") || n.hasPrefix("load") || n.hasPrefix("read") || n.hasPrefix("find") { return "read" }
    if n.hasPrefix("set") || n.hasPrefix("update") || n.hasPrefix("save") || n.hasPrefix("write") { return "write" }
    if n.hasPrefix("create") || n.hasPrefix("make") || n.hasPrefix("build") || n.hasPrefix("init") { return "create" }
    if n.hasPrefix("delete") || n.hasPrefix("remove") || n.hasPrefix("clear") { return "delete" }
    if n.hasPrefix("render") || n.hasPrefix("draw") || n.hasPrefix("display") || n.hasPrefix("show") { return "render" }
    if n.hasPrefix("validate") || n.hasPrefix("check") || n.hasPrefix("verify") { return "validate" }
    if n.hasPrefix("configure") || n.hasPrefix("setup") || n.hasPrefix("register") { return "setup" }
    if n.hasPrefix("handle") || n.hasPrefix("did") || n.hasPrefix("will") || n.hasPrefix("process") { return "handle" }
    if n.hasPrefix("parse") || n.hasPrefix("decode") || n.hasPrefix("encode") || n.hasPrefix("transform") { return "transform" }
    return nil
}

private func inferStructPurpose(_ name: String) -> String? {
    let n = name.lowercased()
    if n.contains("config") || n.contains("setting") || n.contains("option") { return "configuration" }
    if n.contains("request") || n.contains("response") || n.contains("payload") { return "data_transfer" }
    if n.contains("model") || n.contains("entity") || n.contains("data") || n.contains("info") { return "data_model" }
    if n.contains("state") { return "state_container" }
    if n.contains("error") || n.contains("failure") { return "error_type" }
    return nil
}

private func inferEnumPurpose(_ name: String) -> String? {
    let n = name.lowercased()
    if n.contains("route") || n.contains("screen") || n.contains("destination") || n.contains("tab") { return "navigation" }
    if n.contains("state") || n.contains("status") || n.contains("phase") { return "state_machine" }
    if n.contains("error") || n.contains("failure") { return "error_cases" }
    if n.contains("action") || n.contains("event") || n.contains("command") { return "action_dispatch" }
    if n.contains("type") || n.contains("kind") || n.contains("category") { return "classification" }
    return nil
}

/// Scan merged source (containing extension blocks after "// --- extension ---" markers)
/// to infer what capabilities the extensions add to the base type.
private func inferExtensionCapabilities(_ mergedSource: String?) -> String? {
    guard let src = mergedSource else { return nil }
    let extParts = src.components(separatedBy: "// --- extension ---")
    guard extParts.count > 1 else { return nil }

    let extSource = extParts.dropFirst().joined(separator: "\n")
    var capabilities: [String] = []

    if extSource.contains("Codable") || extSource.contains("Decodable") || extSource.contains("Encodable") { capabilities.append("coding") }
    if extSource.contains("Equatable") || extSource.contains("Hashable") { capabilities.append("equality") }
    if extSource.contains("CustomStringConvertible") { capabilities.append("debug_description") }
    if extSource.contains("tableView") || extSource.contains("collectionView") || extSource.contains("UITableView") { capabilities.append("table_data_source") }
    if extSource.contains("@objc") || extSource.contains("#selector") || extSource.contains("@IBAction") { capabilities.append("objc_actions") }
    if extSource.contains("snp.") || extSource.contains("makeConstraints") || extSource.contains("NSLayoutConstraint") { capabilities.append("layout") }
    if extSource.contains("style") || extSource.contains("theme") || extSource.contains("backgroundColor") { capabilities.append("styling") }
    if extSource.contains("@Published") || extSource.contains("@State") || extSource.contains("Combine") { capabilities.append("reactive") }
    if extSource.contains("PreviewProvider") || extSource.contains("#Preview") { capabilities.append("preview") }

    if capabilities.isEmpty {
        // Count functions as generic signal
        let funcCount = extSource.components(separatedBy: "func ").count - 1
        if funcCount > 0 { return "\(funcCount)_methods" }
        return nil
    }

    return capabilities.prefix(4).joined(separator: ",")
}

/// Analyze init/deinit lifecycle for an object node.
private func analyzeLifecycle(_ node: FlatMapEntry, _ sourceCode: String?) -> (ini: String?, di: String?) {
    var ini: String? = nil
    var di: String? = nil

    // ── Init analysis ──
    let hasInits = node.inits != nil && !(node.inits!.isEmpty)
    if hasInits || sourceCode != nil {
        var traits: [String] = []
        if hasInits {
            let deps = node.inits!.prefix(4).map(leafName)
            let callsExternal = deps.contains { !["self", "super"].contains($0.lowercased()) }
            traits.append(callsExternal ? "triggers_logic" : "assign_only")
            traits.append(contentsOf: deps)
        }
        if let src = sourceCode {
            if src.contains("init(") || src.contains("init (") {
                if traits.isEmpty { traits.append("assign_only") }
                if src.contains("addObserver") || src.contains(".observe(") { traits.append("add_observers") }
                if src.contains("URLSession") || src.contains("connect") || src.contains(".start()") { traits.append("conn_remote") }
                if src.contains("Timer.") || src.contains("schedule") { traits.append("start_timer") }
                if src.contains("super.init") { traits.append("calls_super") }
            }
        }
        let unique = Array(Set(traits))
        if !unique.isEmpty { ini = unique.prefix(4).joined(separator: ",") }
    }

    // ── Deinit analysis (reference types only) ──
    if node.flavor == "class" || node.flavor == "actor" {
        var traits: [String] = []
        if let deinits = node.deinits, !deinits.isEmpty {
            traits.append(contentsOf: deinits.prefix(4).map(leafName))
        }
        if let src = sourceCode, src.contains("deinit") {
            if src.contains("cancel()") || src.contains(".cancel") { traits.append("cancel_tasks") }
            if src.contains("removeObserver") { traits.append("remove_observers") }
            if src.contains("close()") || src.contains("disconnect") { traits.append("close_conn") }
            if src.contains("invalidate()") { traits.append("stop_timer") }
            if traits.isEmpty { traits.append("cleanup") }
        }
        let unique = Array(Set(traits))
        if !unique.isEmpty { di = unique.prefix(4).joined(separator: ",") }
    }

    return (ini, di)
}

/// Summarize accessor behaviors (willSet/didSet/computed) from children contexts.
private func summarizeAccessors(_ childContexts: [String]) -> String? {
    var accessors: [String] = []
    for ctx in childContexts {
        // Match e:ws, e:ds, e:g, e:st patterns
        guard let execRange = ctx.range(of: #"^e:(ws|ds|g|st)"#, options: .regularExpression) else { continue }
        let tag = String(ctx[execRange]).split(separator: ":").last.map(String.init) ?? ""

        // Extract intent
        if let intentRange = ctx.range(of: #"\|i:([^|]+)"#, options: .regularExpression) {
            let intentFull = String(ctx[intentRange])
            let intent = intentFull.split(separator: ":").last.map(String.init) ?? ""
            accessors.append("\(tag)>\(intent)")
        } else {
            accessors.append(tag)
        }
    }
    return accessors.isEmpty ? nil : accessors.prefix(4).joined(separator: ",")
}

/// Determine the executable sub-tag for function-like nodes.
/// Returns nil for type-level nodes (class, struct, etc.) — they get t: instead.
private func inferExecTag(_ node: FlatMapEntry) -> String? {
    let name = node.name.lowercased()
    if node.flavor == "variable" {
        if name == "willset" || name.hasSuffix(".willset") { return "ws" }
        if name == "didset" || name.hasSuffix(".didset") { return "ds" }
        if name == "getter" || name.hasSuffix(".get") { return "g" }
        if name == "setter" || name.hasSuffix(".set") { return "st" }
        return "g" // computed property default
    }
    if node.flavor == "initializer" { return "i" }
    if node.flavor == "function" {
        if name == "deinit" { return "di" }
        return "f"
    }
    if node.flavor == "entry_point" { return "f" }
    return nil
}

private func inferAppleRole(_ name: String) -> String {
    let roles: [String: String] = [
        "UIKit": "UI_framework", "SwiftUI": "declarative_UI", "Foundation": "core_runtime",
        "CoreData": "persistence", "Combine": "reactive_streams", "MapKit": "maps",
        "AVFoundation": "audio_video", "Photos": "photo_library", "StoreKit": "in_app_purchase",
        "CloudKit": "cloud_sync", "CoreLocation": "location", "CoreGraphics": "2D_graphics",
        "Metal": "GPU_graphics", "Security": "crypto_keychain", "CryptoKit": "cryptography",
    ]
    return roles[name] ?? "apple_sdk"
}

// MARK: - Main Generator

private let eligibleFlavors: Set<String> = [
    "function", "class", "struct", "enum", "actor", "protocol", "macro",
    "entry_point", "target", "variable", "initializer",
]

struct SemanticContextGenerator {
    let fileSources: [(path: String, tree: SourceFileSyntax)]
    let cacheDir: String
    let ollamaModel: String

    private var cachePath: String { cacheDir + "/semantic-cache.json" }

    init(fileSources: [(path: String, tree: SourceFileSyntax)],
         cacheDir: String,
         ollamaModel: String = "mistral") {
        self.fileSources = fileSources
        self.cacheDir = cacheDir
        self.ollamaModel = ollamaModel
    }

    /// Two-pass enrichment: leaf nodes first, then parent nodes.
    func enrich(_ entries: inout [FlatMapEntry]) -> (generated: Int, cached: Int, llmUsed: Bool) {
        let extractor = SourceExtractor(fileSources: fileSources)
        var cache = loadCache()
        var generated = 0
        var cached = 0
        let llmAvailable = checkOllamaAvailable()

        fputs("{\"_info\":\"Ollama \(llmAvailable ? "available" : "not available") (model: \(ollamaModel))\"}\n", stderr)

        // Build parent→children index
        let idToIndex = Dictionary(entries.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var childrenOf: [String: [String]] = [:]
        for entry in entries {
            for pid in entry.parents {
                if idToIndex[pid] != nil {
                    childrenOf[pid, default: []].append(entry.id)
                }
            }
        }

        // Build reverse caller index
        var callersOf: [String: [String]] = [:]
        for entry in entries {
            for callId in entry.calls ?? [] {
                callersOf[callId, default: []].append(entry.name)
            }
        }

        // Pass 1: Leaf nodes (non-object) + targets
        for i in entries.indices {
            guard eligibleFlavors.contains(entries[i].flavor) else { continue }
            guard !objectFlavors.contains(entries[i].flavor) else { continue }
            processEntry(
                &entries, index: i, extractor: extractor, cache: &cache,
                llmAvailable: llmAvailable, generated: &generated, cached: &cached,
                childrenOf: childrenOf, callersOf: callersOf
            )
        }

        // Pass 2: Parent nodes (can now read children's contexts)
        for i in entries.indices {
            guard objectFlavors.contains(entries[i].flavor) else { continue }
            processEntry(
                &entries, index: i, extractor: extractor, cache: &cache,
                llmAvailable: llmAvailable, generated: &generated, cached: &cached,
                childrenOf: childrenOf, callersOf: callersOf
            )
        }

        // Pass 3: File-level and target-level hierarchical summaries
        let fileSummaries = buildFileSummaries(entries)
        let targetSummaries = buildTargetSummaries(entries)

        // Persist as metadata file for MCP consumption
        let metaPath = cacheDir + "/_meta_summaries.json"
        if let data = try? JSONSerialization.data(
            withJSONObject: ["files": fileSummaries, "targets": targetSummaries],
            options: []
        ) {
            try? data.write(to: URL(fileURLWithPath: metaPath))
        }

        saveCache(cache)
        return (generated, cached, llmAvailable)
    }

    private func buildFileSummaries(_ entries: [FlatMapEntry]) -> [String: String] {
        var byFile: [String: [FlatMapEntry]] = [:]
        for e in entries where e.flavor != "target" && !e.location.absPath.isEmpty {
            byFile[e.location.absPath, default: []].append(e)
        }

        var summaries: [String: String] = [:]
        for (filePath, fileEntries) in byFile {
            let fileName = filePath.split(separator: "/").last.map(String.init) ?? filePath
            var intents: [String] = []
            var types = Set<String>()

            for e in fileEntries {
                guard let ctx = e.semanticContext else { continue }
                for seg in ctx.split(separator: "|") {
                    let s = String(seg)
                    if s.hasPrefix("t:") || s.hasPrefix("e:") { types.insert(s) }
                    if s.hasPrefix("i:") {
                        let val = String(s.dropFirst(2))
                        if !val.isEmpty && !intents.contains(val) { intents.append(val) }
                    }
                }
            }

            var parts = ["t:f", "n:\(fileName)"]
            if !intents.isEmpty { parts.append("i:\(intents.prefix(4).joined(separator: ","))") }
            if !types.isEmpty { parts.append("contains:\(types.prefix(6).joined(separator: ","))") }
            parts.append("count:\(fileEntries.count)")

            summaries[filePath] = parts.joined(separator: "|")
        }
        return summaries
    }

    private func buildTargetSummaries(_ entries: [FlatMapEntry]) -> [String: String] {
        var summaries: [String: String] = [:]
        for e in entries where e.flavor == "target" {
            let prefix = "\(e.id)::"
            let contained = entries.filter { $0.id.hasPrefix(prefix) && $0.flavor != "target" }
            let objectCount = contained.filter { objectFlavors.contains($0.flavor) }.count
            let funcCount = contained.filter { $0.flavor == "function" || $0.flavor == "variable" }.count

            var intents: [String] = []
            for c in contained {
                guard let ctx = c.semanticContext else { continue }
                for seg in ctx.split(separator: "|") {
                    let s = String(seg)
                    if s.hasPrefix("i:") {
                        let val = String(s.dropFirst(2))
                        if !val.isEmpty && !intents.contains(val) { intents.append(val) }
                    }
                }
            }

            let existing = e.semanticContext
            var parts: [String] = existing.map { [$0] } ?? ["t:tg|i:\(e.origin.map { $0 == "Apple" ? "apple_sdk" : "third_party" } ?? "internal")"]
            if objectCount > 0 { parts.append("types:\(objectCount)") }
            if funcCount > 0 { parts.append("funcs:\(funcCount)") }
            if existing == nil && !intents.isEmpty { parts.append("scope:\(intents.prefix(4).joined(separator: ","))") }

            summaries[e.id] = parts.joined(separator: "|")
        }
        return summaries
    }

    private func processEntry(
        _ entries: inout [FlatMapEntry],
        index i: Int,
        extractor: SourceExtractor,
        cache: inout SemanticCache,
        llmAvailable: Bool,
        generated: inout Int,
        cached: inout Int,
        childrenOf: [String: [String]],
        callersOf: [String: [String]]
    ) {
        let entry = entries[i]
        let isTarget = entry.flavor == "target"
        let isParent = objectFlavors.contains(entry.flavor)

        // Gather children contexts for parent nodes
        let childContexts: [String] = isParent
            ? (childrenOf[entry.id] ?? []).compactMap { childId in
                entries.first(where: { $0.id == childId })?.semanticContext
            }
            : []

        let callerNames = isTarget ? (callersOf[entry.id] ?? []) : []

        // For object nodes, merge primary definition + all extension blocks
        var sourceCode: String? = nil
        var extensionCount = 0
        if !isTarget {
            if isParent, let locs = entry.locations, !locs.isEmpty {
                var blocks: [String] = []
                if let primary = extractor.extract(filePath: entry.location.absPath, line: entry.location.line) {
                    blocks.append(primary)
                }
                for loc in locs {
                    if let extSrc = extractor.extract(filePath: loc.absPath, line: loc.line) {
                        blocks.append(extSrc)
                    }
                }
                sourceCode = blocks.isEmpty ? nil : blocks.joined(separator: "\n\n// --- extension ---\n\n")
                extensionCount = locs.count
            } else {
                sourceCode = extractor.extract(filePath: entry.location.absPath, line: entry.location.line)
            }
        }

        // Hash includes extension count + children count for parents
        var hashInput = sourceCode ?? "\(entry.id):\(entry.flavor):\(entry.name)"
        if isTarget { hashInput = "\(entry.id):\(entry.origin ?? ""):\(callerNames.prefix(5).joined(separator: ","))" }
        if extensionCount > 0 { hashInput += "|ext:\(extensionCount)" }
        if !childContexts.isEmpty { hashInput += "|children:\(childContexts.count)" }
        if let inits = entry.inits, !inits.isEmpty { hashInput += "|inits:\(inits.joined(separator: ","))" }
        if let deinits = entry.deinits, !deinits.isEmpty { hashInput += "|deinits:\(deinits.joined(separator: ","))" }
        let hash = sha256Hash(hashInput)

        if let cachedEntry = cache.entries[entry.id], cachedEntry.hash == hash {
            entries[i].semanticContext = cachedEntry.context
            cached += 1
            return
        }

        // Try LLM with flavor-specific prompt (merged source includes extensions)
        var context: String?
        if llmAvailable {
            if isTarget {
                context = queryLocalLLM(sourceCode: buildLibraryPrompt(entry: entry, callerNames: callerNames), model: ollamaModel)
            } else if let src = sourceCode {
                context = queryLocalLLM(sourceCode: buildLLMPrompt(sourceCode: src, childContexts: childContexts), model: ollamaModel)
            }
        }

        if context == nil {
            context = generateStructuralContext(node: entry, sourceCode: sourceCode, childContexts: childContexts, callerNames: callerNames, extensionCount: extensionCount)
        }

        if let ctx = context {
            entries[i].semanticContext = ctx
            cache.entries[entry.id] = SemanticCacheEntry(
                hash: hash, context: ctx, generatedAt: ISO8601DateFormatter().string(from: Date())
            )
            generated += 1
        }
    }

    private func checkOllamaAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ollama", "list"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func loadCache() -> SemanticCache {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let cache = try? JSONDecoder().decode(SemanticCache.self, from: data) else {
            return SemanticCache()
        }
        return cache
    }

    private func saveCache(_ cache: SemanticCache) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDir) {
            try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: URL(fileURLWithPath: cachePath))
    }
}
