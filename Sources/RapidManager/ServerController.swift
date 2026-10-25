import AppKit
import SwiftUI
import Foundation

enum ServerStatus: Equatable {
    case stopped, starting, running, stopping, external
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .external: return "Running (started elsewhere)"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .stopped: return .gray
        case .starting, .stopping: return .orange
        case .running: return .green
        case .external: return .blue
        case .failed: return .red
        }
    }
}

struct LogLine: Identifiable {
    let id: Int
    let text: String
}

@MainActor
final class ServerController: ObservableObject {
    @Published private(set) var status: ServerStatus = .stopped
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var busy = false

    @Published var binaryPath: String { didSet { defaults.set(binaryPath, forKey: Keys.binary) } }
    @Published var modelsDir: String { didSet { defaults.set(modelsDir, forKey: Keys.modelsDir) } }
    @Published var activeModel: String { didSet { defaults.set(activeModel, forKey: Keys.model) } }
    @Published private(set) var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    @Published private(set) var port: String { didSet { defaults.set(port, forKey: Keys.port) } }
    /// Unchecked = server is started with --no-thinking.
    @Published private(set) var thinking: Bool { didSet { defaults.set(thinking, forKey: Keys.thinking) } }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let binary = "binaryPath"
        static let modelsDir = "modelsDir"
        static let model = "activeModel"
        static let host = "host"
        static let port = "port"
        static let thinking = "thinking"
    }

    private var process: Process?
    private var userStopped = false
    private var carry = ""
    private var nextLogID = 0
    private var timer: Timer?

    var hasProcess: Bool { process != nil }

    func setThinking(_ on: Bool) {
        guard on != thinking else { return }
        thinking = on
        if hasProcess && !busy { restart() }      // the flag only takes effect on a fresh start
    }

    func applyEndpoint(host h: String, port p: String) {
        let hh = h.trimmingCharacters(in: .whitespaces)
        let pp = p.trimmingCharacters(in: .whitespaces)
        host = hh.isEmpty ? Config.defaultHost : hh
        port = (Int(pp).map { (1...65535).contains($0) } ?? false) ? pp : String(Config.defaultPort)
        if hasProcess && !busy { restart() } else { Task { await pollHealth() } }
    }

    func showManager() {
        WindowManager.shared.show(id: "models", title: "Rapid-MLX Models", size: NSSize(width: 780, height: 560), closeOnEsc: true) {
            ModelManagerView().environmentObject(self).environmentObject(manager)
        }
    }

    func toggleManager() {
        if WindowManager.shared.isVisible(id: "models") {
            WindowManager.shared.hide(id: "models")
        } else {
            showManager()
        }
    }

    /// Model management (rapid-mlx models / pull / rm / ps).
    lazy var manager = ModelsManager(controller: self)

    init() {
        let d = UserDefaults.standard
        binaryPath = d.string(forKey: Keys.binary) ?? BinaryLocator.detect() ?? ""
        modelsDir = d.string(forKey: Keys.modelsDir) ?? ""
        activeModel = d.string(forKey: Keys.model) ?? ""
        host = d.string(forKey: Keys.host) ?? Config.defaultHost
        port = d.string(forKey: Keys.port) ?? String(Config.defaultPort)
        thinking = d.object(forKey: Keys.thinking) as? Bool ?? true

        // Don't leave an orphaned server behind when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            ProcessTree.terminate(PIDBox.shared.pid)
        }

        // Right-click on the menu bar icon toggles the Models window.
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let w = event.window,
                  w.className.contains("StatusBar") || w.level == .statusBar else { return event }
            Task { @MainActor in self?.toggleManager() }
            return nil
        }

        refreshModels()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollHealth() }
        }
        Task { await pollHealth() }
    }

    // MARK: Models

    @Published private(set) var scannedPaths: [String] = []

    func refreshModels() {
        let roots = modelsDir.isEmpty
            ? ModelScanner.defaultRoots()
            : [URL(fileURLWithPath: (modelsDir as NSString).expandingTildeInPath)]
        scannedPaths = roots.map(\.path)
        log("Refresh models: scanning \(roots.count) folder(s)")
        Task {
            let result = await Task.detached { ModelScanner.scan(roots: roots) }.value
            for n in result.notes { log(n) }
            log("Refresh models: found \(result.models.count) model(s)")
            models = result.models
            if activeModel.isEmpty, let first = result.models.first { activeModel = first.id }
        }
    }

    /// Makes `id` the active model; if the server is up it is restarted with the new model.
    func select(_ id: String) {
        guard id != activeModel, !busy else { return }
        let wasRunning = hasProcess
        activeModel = id
        if wasRunning { restart() }
    }

    // MARK: Start / stop

    func start() {
        guard !busy, !hasProcess else { return }
        busy = true
        Task {
            if await isUp() {
                status = .external
                log("Port \(Config.port) is already served by another process. Stop it first.")
            } else {
                launch()
            }
            busy = false
        }
    }

    func stopServer() {
        guard !busy else { return }
        busy = true
        Task { await stop(); busy = false }
    }

    func restart() {
        guard !busy else { return }
        busy = true
        Task {
            await stop()
            await waitForPortFree()
            launch()
            busy = false
        }
    }

    private func launch() {
        guard !activeModel.isEmpty else { fail("No model selected."); return }
        let path = (binaryPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            fail("Rapid-MLX binary not found: \(path.isEmpty ? "(not set)" : path). Set it in Settings.")
            return
        }

        var args = ["serve", activeModel, "--host", Config.host, "--port", String(Config.port)]
        if !thinking { args.append("--no-thinking") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args

        var env = ProcessInfo.processInfo.environment
        let binDir = (path as NSString).deletingLastPathComponent
        env["PATH"] = [binDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        if !modelsDir.isEmpty { env["HF_HUB_CACHE"] = (modelsDir as NSString).expandingTildeInPath }
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finish(proc) }
        }

        log("$ \(path) \(args.joined(separator: " "))")
        do {
            userStopped = false
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            fail("Could not launch: \(error.localizedDescription)")
            return
        }
        process = p
        PIDBox.shared.pid = p.processIdentifier
        status = .starting
    }

    private func stop() async {
        guard let p = process else {
            if status != .external { status = .stopped }
            return
        }
        userStopped = true
        status = .stopping
        let pid = p.processIdentifier
        let tree = ProcessTree.descendants(of: pid)
        p.terminate()
        for c in tree { kill(c, SIGTERM) }

        var ticks = 0
        while p.isRunning && ticks < 100 {          // up to ~10 s for a graceful exit
            try? await Task.sleep(nanoseconds: 100_000_000)
            ticks += 1
        }
        if p.isRunning {
            log("Server did not exit in time; sending SIGKILL.")
            kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        for c in tree where ProcessTree.isAlive(c) { kill(c, SIGKILL) }
        if !p.isRunning { finish(p) }
    }

    private func waitForPortFree() async {
        for _ in 0..<40 {                            // up to ~8 s
            if !(await isUp()) { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func finish(_ p: Process) {
        guard process === p else { return }
        if let pipe = p.standardOutput as? Pipe {
            let fh = pipe.fileHandleForReading
            if let rest = try? fh.readToEnd() { ingest(rest) }
            fh.readabilityHandler = nil
        }
        if !carry.isEmpty { emit(carry); carry = "" }
        process = nil
        PIDBox.shared.pid = 0
        if userStopped {
            status = .stopped
            log("Server stopped.")
        } else {
            let msg = "Server exited unexpectedly (code \(p.terminationStatus))."
            status = .failed(msg)
            log(msg)
        }
        userStopped = false
    }

    private func fail(_ message: String) {
        status = .failed(message)
        log(message)
    }

    // MARK: Health

    private func isUp() async -> Bool {
        await Task.detached { Probe.portOpen(host: Config.probeHost, port: Config.port) }.value
    }

    private func pollHealth() async {
        let up = await isUp()
        if status == .stopping { return }
        if process != nil {
            status = up ? .running : .starting
        } else if up {
            status = .external
        } else if status == .external {
            status = .stopped
        }
    }

    // MARK: Logs

    func clearLogs() { logs.removeAll() }

    var allLogText: String { logs.map(\.text).joined(separator: "\n") }

    func log(_ text: String) { append("▸ " + text) }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        carry += String(decoding: data, as: UTF8.self)
        var parts = carry.components(separatedBy: "\n")
        carry = parts.removeLast()
        for part in parts { emit(part) }
        if carry.count > 8192 { emit(carry); carry = "" }
    }

    private func emit(_ raw: String) {
        // Progress bars redraw with "\r"; keep only the final state of the line.
        let last = raw.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? ""
        let clean = last.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        append(clean)
    }

    private func append(_ text: String) {
        logs.append(LogLine(id: nextLogID, text: text))
        nextLogID += 1
        if logs.count > 3000 { logs.removeFirst(500) }
    }
}
