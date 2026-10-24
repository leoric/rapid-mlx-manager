import SwiftUI
import AppKit

// MARK: - Window helper (reliable for menu-bar-only apps)

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func isVisible(id: String) -> Bool { windows[id]?.isVisible ?? false }
    func hide(id: String) { windows[id]?.orderOut(nil) }

    func show<V: View>(id: String, title: String, size: NSSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Menu bar panel

struct MenuView: View {
    @EnvironmentObject var c: ServerController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            controls
            Divider()
            modelList
            Divider()
            HStack {
                Button("Manage…") { c.showManager() }
                Button("Logs…") {
                    WindowManager.shared.show(id: "logs", title: "Rapid-MLX Logs", size: NSSize(width: 680, height: 420)) {
                        LogView().environmentObject(c)
                    }
                }
                Button("Settings…") {
                    WindowManager.shared.show(id: "settings", title: "Rapid-MLX Settings", size: NSSize(width: 480, height: 420)) {
                        SettingsView().environmentObject(c)
                    }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { c.refreshModels() }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(c.status.color).frame(width: 10, height: 10)
                Text(c.status.label).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Config.endpoint, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy \(Config.endpoint)")
            }
            Text(Config.endpoint).font(.caption).foregroundStyle(.secondary)
            if !c.activeModel.isEmpty {
                Text("Model: \(c.activeModel)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if case .failed(let msg) = c.status {
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3)
            } else if case .external = c.status {
                Text("Another process is serving this port. See Manage… → Servers (rapid-mlx ps).")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if let last = c.logs.last?.text {
                Text(last).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private var controls: some View {
        HStack {
            if c.hasProcess {
                Button("Stop") { c.stopServer() }
                Button("Restart") { c.restart() }
            } else {
                Button("Start") { c.start() }
                    .disabled(c.status == .external)
            }
            Spacer()
            if c.busy { ProgressView().controlSize(.small) }
        }
        .disabled(c.busy)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Models").font(.subheadline.weight(.semibold))
                Spacer()
                Button { c.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan models folder")
            }
            if c.models.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No models found. Looked in:").font(.caption).foregroundStyle(.secondary)
                    ForEach(c.scannedPaths, id: \.self) { p in
                        Text(p).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text("Set the models folder in Settings.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(c.models) { m in
                            Button { c.select(m.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: m.id == c.activeModel ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(m.id == c.activeModel ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(m.displayName).lineLimit(1).truncationMode(.middle)
                                        if !m.org.isEmpty {
                                            Text(m.org).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(c.busy)
                        }
                    }
                }
                // ScrollView has no intrinsic height and collapses to 0 in a window-style
                // MenuBarExtra, so give it an explicit height based on the row count.
                .frame(height: min(260, CGFloat(c.models.count) * 40 + 4))
            }
        }
    }
}

// MARK: - Logs window

struct LogView: View {
    @EnvironmentObject var c: ServerController
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(c.logs) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: c.logs.last?.id) { _ in
                    if follow, let id = c.logs.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Circle().fill(c.status.color).frame(width: 9, height: 9)
                Text(c.status.label).font(.caption)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.allLogText, forType: .string)
                }
                Button("Clear") { c.clearLogs() }
            }
            .padding(8)
        }
        .frame(minWidth: 520, minHeight: 300)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var c: ServerController

    private var binaryOK: Bool {
        FileManager.default.isExecutableFile(atPath: (c.binaryPath as NSString).expandingTildeInPath)
    }

    var body: some View {
        Form {
            Section("Rapid-MLX binary") {
                HStack {
                    TextField("Path to rapid-mlx", text: $c.binaryPath)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: binaryOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(binaryOK ? .green : .red)
                }
                HStack {
                    Button("Choose…") {
                        if let p = pick(directory: false, start: c.binaryPath) { c.binaryPath = p }
                    }
                    Button("Auto-detect") {
                        if let p = BinaryLocator.detect() { c.binaryPath = p }
                    }
                    Spacer()
                }
                Text("Used the next time the server starts.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Models folder") {
                TextField("Default: ~/.cache/huggingface (and hub), ~/.cache/rapid-mlx", text: $c.modelsDir)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Choose…") {
                        if let p = pick(directory: true, start: c.modelsDir) { c.modelsDir = p }
                    }
                    Button("Use default") { c.modelsDir = "" }
                    Spacer()
                }
                Text("If set, it is also passed to Rapid-MLX as HF_HUB_CACHE.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Endpoint") {
                LabeledContent("Address", value: Config.endpoint)
                Text("Fixed, so existing clients keep working when you switch models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: c.modelsDir) { _ in c.refreshModels() }
        .frame(minWidth: 460, minHeight: 400)
    }

    private func pick(directory: Bool, start: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let expanded = (start as NSString).expandingTildeInPath
        if !expanded.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
