import Foundation
import Darwin

// MARK: - Models

struct LocalModel: Identifiable, Hashable {
    let id: String          // HF repo id ("org/name") or an absolute folder path

    var isPath: Bool { id.hasPrefix("/") }
    var displayName: String { id.split(separator: "/").last.map(String.init) ?? id }
    var org: String {
        let parts = id.split(separator: "/")
        if isPath { return parts.count >= 2 ? String(parts[parts.count - 2]) : "" }
        return parts.count >= 2 ? String(parts[0]) : ""
    }
}

enum ModelScanner {
    static func defaultHubDir() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["HF_HUB_CACHE"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        if let p = env["HF_HOME"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath).appendingPathComponent("hub")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// Folders searched when no custom models folder is set.
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            defaultHubDir(),
            home.appendingPathComponent(".cache/huggingface"),
            home.appendingPathComponent(".cache/rapid-mlx"),
            home.appendingPathComponent(".rapid-mlx"),
        ]
    }

    struct ScanResult {
        var models: [LocalModel] = []
        var notes: [String] = []
    }

    /// Finds downloaded models (HF cache layout or plain folders with config.json + *.safetensors).
    static func scan(roots: [URL]) -> ScanResult {
        var found: [String: LocalModel] = [:]
        var notes: [String] = []
        for root in roots {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) {
                notes.append("scan: \(root.path) does not exist")
                continue
            }
            walk(root, depth: 0, into: &found, notes: &notes)
        }
        let models = found.values.sorted { $0.id.lowercased() < $1.id.lowercased() }
        return ScanResult(models: models, notes: notes)
    }

    private static func walk(_ dir: URL, depth: Int, into found: inout [String: LocalModel], notes: inout [String]) {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            notes.append("scan: cannot read \(dir.path): \(error.localizedDescription)")
            return
        }
        if depth == 0 { notes.append("scan: \(dir.path) has \(entries.count) entries") }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if name.hasPrefix("models--") {
                let repo = name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
                guard let snap = latestSnapshot(entry) else {
                    notes.append("scan: skipped \(repo): no snapshot with config.json + .safetensors")
                    continue
                }
                if found[repo] == nil {
                    found[repo] = LocalModel(id: repo)
                    notes.append("scan: found \(repo) (\(snap.lastPathComponent.prefix(8)))")
                }
            } else if hasWeights(entry) {
                let path = entry.standardizedFileURL.path
                if found[path] == nil { found[path] = LocalModel(id: path) }
            } else if depth < 3, name != "blobs", name != "snapshots" {
                walk(entry, depth: depth + 1, into: &found, notes: &notes)
            }
        }
    }

    private static func hasWeights(_ dir: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
    }

    private static func modDate(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func latestSnapshot(_ repoDir: URL) -> URL? {
        let snaps = repoDir.appendingPathComponent("snapshots")
        let items = (try? FileManager.default.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil)) ?? []
        return items.filter(hasWeights).max { modDate($0) < modDate($1) }
    }
}

// MARK: - Binary discovery

enum BinaryLocator {
    static func detect() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.rapid-mlx/bin/rapid-mlx",
            "/opt/homebrew/bin/rapid-mlx",
            "/usr/local/bin/rapid-mlx",
            "\(home)/.local/bin/rapid-mlx",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }

        // Fall back to the user's login shell PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v rapid-mlx"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

// MARK: - Process helpers

/// Lets the quit notification kill the server without touching actor state.
final class PIDBox: @unchecked Sendable {
    static let shared = PIDBox()
    var pid: pid_t = 0
}

enum ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        var all: [pid_t] = []
        for c in children(of: pid) { all.append(c); all += descendants(of: c) }
        return all
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    static func terminate(_ pid: pid_t) {
        guard pid > 0 else { return }
        let tree = descendants(of: pid) + [pid]
        for p in tree { kill(p, SIGTERM) }
    }
}

enum Probe {
    /// Plain TCP connect, so polling doesn't spam the server log with HTTP requests.
    static func portOpen(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }
}
