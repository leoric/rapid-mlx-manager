import Foundation

final class DataBox: @unchecked Sendable { var data = Data() }

struct CaptureResult {
    let code: Int32
    let out: String
    let err: String
    var combined: String { [out, err].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum LogText {
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
    /// Progress bars redraw with "\r"; keep only the last non-empty segment.
    static func clean(_ raw: String) -> String {
        let last = raw.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? ""
        return stripANSI(last)
    }
}

enum CLI {
    static func binaryPath(_ raw: String) -> String? {
        let p = (raw as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static func environment(binary: String, modelsDir: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binDir = (binary as NSString).deletingLastPathComponent
        env["PATH"] = [binDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        if !modelsDir.isEmpty { env["HF_HUB_CACHE"] = (modelsDir as NSString).expandingTildeInPath }
        return env
    }

    /// Runs a short-lived command and captures stdout/stderr.
    static func capture(_ exe: String, _ args: [String], env: [String: String],
                        stdin: String? = nil, timeout: TimeInterval = 60) async -> CaptureResult {
        await withCheckedContinuation { (cont: CheckedContinuation<CaptureResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = env
                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
                do { try p.run() } catch {
                    cont.resume(returning: CaptureResult(code: -1, out: "", err: "Could not launch: \(error.localizedDescription)"))
                    return
                }
                if let stdin {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                let outBox = DataBox(), errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let timeoutItem = DispatchWorkItem { if p.isRunning { ProcessTree.terminate(p.processIdentifier) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
                p.waitUntilExit()
                group.wait()
                timeoutItem.cancel()
                cont.resume(returning: CaptureResult(
                    code: p.terminationStatus,
                    out: LogText.stripANSI(String(decoding: outBox.data, as: UTF8.self)),
                    err: LogText.stripANSI(String(decoding: errBox.data, as: UTF8.self))))
            }
        }
    }
}

/// A long-running CLI command (pull / rm) with streamed output.
@MainActor
final class CLIJob: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published private(set) var lines: [String] = []
    @Published private(set) var live = ""
    @Published private(set) var running = true
    @Published private(set) var exitCode: Int32?

    private var process: Process?
    private var carry = ""
    private var cancelled = false
    private let onFinish: (CLIJob) -> Void

    init(title: String, exe: String, args: [String], env: [String: String],
         stdin: String? = nil, onFinish: @escaping (CLIJob) -> Void) {
        self.title = title
        self.onFinish = onFinish
        lines.append("$ " + ([exe] + args).joined(separator: " "))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.ingest(d) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finish(proc) }
        }
        do {
            try p.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            lines.append("Could not launch: \(error.localizedDescription)")
            running = false
            exitCode = -1
            Task { @MainActor in onFinish(self) }
            return
        }
        process = p
        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
    }

    func cancel() {
        guard running, let p = process else { return }
        cancelled = true
        ProcessTree.terminate(p.processIdentifier)
    }

    private func ingest(_ data: Data) {
        carry += String(decoding: data, as: UTF8.self)
        var parts = carry.components(separatedBy: "\n")
        carry = parts.removeLast()
        for part in parts {
            let clean = LogText.clean(part)
            if !clean.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(clean) }
        }
        if lines.count > 2000 { lines.removeFirst(500) }
        live = LogText.clean(carry)
    }

    private func finish(_ p: Process) {
        guard process === p, running else { return }
        if let pipe = p.standardOutput as? Pipe {
            let fh = pipe.fileHandleForReading
            if let rest = try? fh.readToEnd() { ingest(rest) }
            fh.readabilityHandler = nil
        }
        let tail = LogText.clean(carry)
        if !tail.isEmpty { lines.append(tail) }
        carry = ""
        live = ""
        running = false
        exitCode = p.terminationStatus
        lines.append(cancelled ? "Cancelled." : "Exit code \(p.terminationStatus)")
        process = nil
        onFinish(self)
    }
}
