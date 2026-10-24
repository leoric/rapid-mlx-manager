import Foundation
import SwiftUI

struct ManagedModel: Identifiable, Hashable {
    let id: String
    let alias: String?
    let repo: String?
    let sizeText: String?      // only what rapid-mlx itself reported; nil is shown as "—"
    let info: String
    let readOnly: Bool

    var title: String { alias ?? repo ?? id }
    var target: String { alias ?? repo ?? id }      // what to pass to pull / rm
    var serveID: String { repo ?? alias ?? id }     // what to pass to serve
    var subtitle: String {
        var parts: [String] = []
        if alias != nil, let repo { parts.append(repo) }
        if !info.isEmpty { parts.append(info) }
        return parts.joined(separator: " · ")
    }
}

/// Tolerant parser for `rapid-mlx models [--cached] --json` output.
enum ModelJSON {
    static func parse(_ text: String) -> [ManagedModel]? {
        guard let obj = decode(text) else { return nil }
        var rows: [[String: Any]] = []
        if let a = obj as? [Any] {
            rows = flatten(a)
        } else if let d = obj as? [String: Any] {
            if let a = firstArray(in: d) {
                rows = flatten(a)
            } else if !d.isEmpty, d.values.allSatisfy({ $0 is [String: Any] }) {
                rows = d.keys.sorted().map { k in
                    var r = d[k] as? [String: Any] ?? [:]
                    if r["alias"] == nil { r["alias"] = k }
                    return r
                }
            } else {
                return nil
            }
        } else {
            return nil
        }
        return rows.enumerated().map { model(from: $0.element, index: $0.offset) }
    }

    private static func decode(_ text: String) -> Any? {
        let lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[") || t.hasPrefix("{") else { continue }
            let chunk = lines[i...].joined(separator: "\n")
            if let d = chunk.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { return o }
        }
        return nil
    }

    private static func flatten(_ a: [Any]) -> [[String: Any]] {
        a.compactMap { item -> [String: Any]? in
            if let d = item as? [String: Any] { return d }
            if let s = item as? String { return ["alias": s] }
            return nil
        }
    }

    private static func firstArray(in d: [String: Any]) -> [Any]? {
        let keys = ["models", "rows", "items", "data", "cached", "catalog", "results", "aliases"]
        for k in keys { if let a = d[k] as? [Any] { return a } }
        for k in keys { if let sub = d[k] as? [String: Any], let a = firstArray(in: sub) { return a } }
        for v in d.values { if let a = v as? [Any], a.contains(where: { $0 is [String: Any] }) { return a } }
        return nil
    }

    private static func model(from r: [String: Any], index: Int) -> ManagedModel {
        func str(_ keys: [String]) -> String? {
            for k in keys { if let s = r[k] as? String, !s.isEmpty { return s } }
            return nil
        }
        var alias = str(["alias", "name", "id", "model", "key"])
        var repo = str(["repo", "repo_id", "hf_repo", "hf_repo_id", "huggingface_repo", "model_id", "hf_id"])
        if repo == nil, let a = alias, a.contains("/") { repo = a; alias = nil }

        var size: String?
        for k in ["size_bytes", "bytes", "disk_bytes", "size_on_disk_bytes", "download_bytes"] {
            if let n = (r[k] as? NSNumber)?.doubleValue, n > 0 {
                size = ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
                break
            }
        }
        if size == nil {
            for k in ["size_human", "size_str", "size", "download_size", "disk_size"] {
                if let s = r[k] as? String, !s.isEmpty, s != "—", s != "-" { size = s; break }
            }
        }

        var parts: [String] = []
        for k in ["modality", "state", "kind", "type", "quant", "quantization", "params"] {
            if let s = r[k] as? String, !s.isEmpty { parts.append(s) }
        }
        if (r["chat_ready"] as? NSNumber)?.boolValue == true { parts.append("chat-ready") }

        let readOnly = ["state", "source", "origin", "location", "kind"].contains {
            (r[$0] as? String)?.lowercased().contains("external") == true
        }
        return ManagedModel(id: "\(alias ?? repo ?? "row")#\(index)", alias: alias, repo: repo,
                            sizeText: size, info: parts.joined(separator: " · "), readOnly: readOnly)
    }
}

@MainActor
final class ModelsManager: ObservableObject {
    unowned let controller: ServerController

    @Published private(set) var cached: [ManagedModel] = []
    @Published private(set) var catalog: [ManagedModel] = []
    @Published private(set) var cachedRaw = ""
    @Published private(set) var catalogRaw = ""
    @Published private(set) var psText = ""
    @Published var cachedError: String?
    @Published private(set) var catalogError: String?
    @Published private(set) var loadingCached = false
    @Published private(set) var loadingCatalog = false
    @Published private(set) var loadingPS = false
    @Published var jobs: [CLIJob] = []
    @Published var search = ""
    @Published var modality = "all"

    init(controller: ServerController) { self.controller = controller }

    var runningJobs: Int { jobs.filter(\.running).count }

    private func binary() -> String? { CLI.binaryPath(controller.binaryPath) }
    private func env(_ exe: String) -> [String: String] { CLI.environment(binary: exe, modelsDir: controller.modelsDir) }
    private static let noBinary = "Rapid-MLX binary not set or not executable. Set it in Settings."

    func isCached(_ m: ManagedModel) -> Bool {
        cached.contains { c in
            (m.alias != nil && c.alias == m.alias) || (m.repo != nil && c.repo == m.repo) || c.title == m.title
        }
    }

    // MARK: Listing

    private func fetch(_ exe: String, args: [String]) async -> (models: [ManagedModel]?, raw: String) {
        let e = env(exe)
        let json = await CLI.capture(exe, args + ["--json"], env: e, timeout: 120)
        if json.code == 0, let models = ModelJSON.parse(json.out) {
            return (models, json.combined)
        }
        let plain = await CLI.capture(exe, args, env: e, timeout: 120)
        let raw = "$ rapid-mlx \((args + ["--json"]).joined(separator: " "))  → exit \(json.code)\n\(json.combined)\n\n"
            + "$ rapid-mlx \(args.joined(separator: " "))  → exit \(plain.code)\n\(plain.combined)"
        return (nil, raw)
    }

    func loadCached() {
        guard let exe = binary() else { cachedError = Self.noBinary; return }
        loadingCached = true
        cachedError = nil
        Task {
            let r = await fetch(exe, args: ["models", "--cached"])
            loadingCached = false
            cachedRaw = r.raw
            if let models = r.models {
                cached = models
            } else {
                cached = []
                cachedError = "Couldn't read the JSON from `rapid-mlx models --cached --json`. See the raw output below."
            }
        }
    }

    func loadCatalog() {
        guard let exe = binary() else { catalogError = Self.noBinary; return }
        var args = ["models"]
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { args += ["--search", q] }
        if modality != "all" { args += ["--modality", modality] }
        loadingCatalog = true
        catalogError = nil
        Task {
            let r = await fetch(exe, args: args)
            loadingCatalog = false
            catalogRaw = r.raw
            if let models = r.models {
                catalog = models
            } else {
                catalog = []
                catalogError = "Couldn't read the JSON from `rapid-mlx models --json`. See the raw output below."
            }
        }
    }

    func loadPS() {
        guard let exe = binary() else { psText = Self.noBinary; return }
        loadingPS = true
        Task {
            let r = await CLI.capture(exe, ["ps"], env: env(exe), timeout: 30)
            loadingPS = false
            psText = r.combined.isEmpty ? "(no output, exit \(r.code))" : r.combined
        }
    }

    // MARK: Pull / remove

    func pull(_ target: String) {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        start(title: "pull \(t)", args: ["pull", t], stdin: nil) {}
    }

    func remove(_ model: ManagedModel) {
        guard let exe = binary() else { cachedError = Self.noBinary; return }
        let e = env(exe)
        Task {
            // `rm` may ask for confirmation; use its own non-interactive flag if it has one.
            let help = await CLI.capture(exe, ["rm", "--help"], env: e, timeout: 20).combined
            var args = ["rm", model.target]
            var stdin: String?
            if help.contains("--yes") { args.append("--yes") }
            else if help.contains("--force") { args.append("--force") }
            else if help.contains("-y,") || help.contains("-y ") { args.append("-y") }
            else { stdin = "y\n" }
            start(title: "rm \(model.target)", args: args, stdin: stdin) { [weak self] in
                guard let self else { return }
                let a = self.controller.activeModel
                if !self.controller.hasProcess, a == model.serveID || a == model.alias || a == model.repo {
                    self.controller.activeModel = ""
                    self.controller.refreshModels()
                }
            }
        }
    }

    private func start(title: String, args: [String], stdin: String?, then: @escaping () -> Void) {
        guard let exe = binary() else { cachedError = Self.noBinary; return }
        let job = CLIJob(title: title, exe: exe, args: args, env: env(exe), stdin: stdin) { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.loadCached()
            self.controller.refreshModels()
            then()
        }
        jobs.append(job)
    }
}
