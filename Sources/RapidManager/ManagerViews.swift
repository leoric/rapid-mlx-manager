import SwiftUI
import AppKit

struct ModelManagerView: View {
    @EnvironmentObject var c: ServerController
    @EnvironmentObject var m: ModelsManager

    enum Tab: String, CaseIterable, Identifiable {
        case downloaded = "Downloaded", catalog = "Catalog", servers = "Servers", activity = "Activity"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .downloaded
    @State private var pendingRemove: ManagedModel?
    @State private var blocked: ManagedModel?
    @State private var manualPull = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t == .activity && m.runningJobs > 0 ? "Activity (\(m.runningJobs))" : t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .downloaded: downloaded
            case .catalog: catalogTab
            case .servers: servers
            case .activity: activity
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear { m.loadCached(); m.loadPS() }
        .onChange(of: tab) { t in
            if t == .catalog, m.catalog.isEmpty { m.loadCatalog() }
            if t == .servers { m.loadPS() }
        }
        .alert("Remove model?", isPresented: Binding(get: { pendingRemove != nil },
                                                      set: { if !$0 { pendingRemove = nil } }),
               presenting: pendingRemove) { model in
            Button("Remove", role: .destructive) { m.remove(model); tab = .activity }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This runs `rapid-mlx rm \(model.target)` and deletes the model from the Hugging Face cache.")
        }
        .alert("Model is in use", isPresented: Binding(get: { blocked != nil },
                                                        set: { if !$0 { blocked = nil } }),
               presenting: blocked) { _ in
            Button("OK") {}
        } message: { _ in
            Text("The running server is using this model. Stop the server or switch to another model first.")
        }
    }

    private func isActive(_ model: ManagedModel) -> Bool {
        let a = c.activeModel
        return !a.isEmpty && (a == model.serveID || a == model.alias || a == model.repo)
    }

    private func requestRemove(_ model: ManagedModel) {
        if c.hasProcess && isActive(model) { blocked = model } else { pendingRemove = model }
    }

    // MARK: Downloaded

    private var downloaded: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(m.cached.count) downloaded").foregroundStyle(.secondary)
                if m.loadingCached { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { m.loadCached() }
            }
            .padding(10)
            if let e = m.cachedError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            List(m.cached) { model in
                HStack(spacing: 10) {
                    Image(systemName: isActive(model) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive(model) ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                        if !model.subtitle.isEmpty {
                            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(model.sizeText ?? "—").foregroundStyle(.secondary).monospacedDigit()
                    Button("Use") { c.select(model.serveID) }
                        .disabled(isActive(model) || c.busy)
                    Button("Remove", role: .destructive) { requestRemove(model) }
                        .disabled(model.readOnly)
                }
                .padding(.vertical, 2)
            }
            rawBox(m.cachedRaw)
        }
    }

    // MARK: Catalog

    private var catalogTab: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search aliases", text: $m.search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { m.loadCatalog() }
                Picker("", selection: $m.modality) {
                    Text("All").tag("all")
                    Text("Text").tag("text")
                    Text("Audio").tag("audio")
                    Text("Video").tag("video-gen")
                    Text("Image").tag("image-gen")
                }
                .labelsHidden()
                .frame(width: 100)
                Button("Search") { m.loadCatalog() }
                if m.loadingCatalog { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .onChange(of: m.modality) { _ in m.loadCatalog() }
            if let e = m.catalogError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            List(m.catalog) { model in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                        if !model.subtitle.isEmpty {
                            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(model.sizeText ?? "—").foregroundStyle(.secondary).monospacedDigit()
                    if m.isCached(model) {
                        Text("Downloaded").font(.caption).foregroundStyle(.green)
                            .frame(width: 80, alignment: .trailing)
                    } else {
                        Button("Pull") { m.pull(model.target); tab = .activity }
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                .padding(.vertical, 2)
            }
            Text("Catalog sizes are approximate download footprints reported by rapid-mlx; “—” means unknown.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
            HStack {
                TextField("Alias or Hugging Face repo to pull", text: $manualPull)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { pullManual() }
                Button("Pull") { pullManual() }
                    .disabled(manualPull.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            rawBox(m.catalogRaw)
        }
    }

    private func pullManual() {
        m.pull(manualPull)
        manualPull = ""
        tab = .activity
    }

    // MARK: Servers (rapid-mlx ps)

    private var servers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output of `rapid-mlx ps`").font(.headline)
                if m.loadingPS { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { m.loadPS() }
            }
            ScrollView {
                Text(m.psText.isEmpty ? "(no output)" : m.psText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding(10)
    }

    // MARK: Activity

    private var activity: some View {
        VStack(spacing: 0) {
            HStack {
                Text(m.jobs.isEmpty ? "No pulls or removals yet" : "\(m.jobs.count) task(s)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear finished") { m.jobs.removeAll { !$0.running } }
                    .disabled(m.jobs.allSatisfy { $0.running })
            }
            .padding(10)
            List(Array(m.jobs.reversed())) { job in JobRow(job: job) }
        }
    }

    private func rawBox(_ text: String) -> some View {
        DisclosureGroup("Raw CLI output") {
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
        }
        .padding(10)
    }
}

struct JobRow: View {
    @ObservedObject var job: CLIJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if job.running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: job.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(job.exitCode == 0 ? Color.green : Color.red)
                }
                Text(job.title).font(.headline)
                Spacer()
                if job.running { Button("Cancel") { job.cancel() } }
            }
            if job.running, !job.live.isEmpty {
                Text(job.live).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            DisclosureGroup("Log") {
                ScrollView {
                    Text(job.lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
        }
        .padding(.vertical, 4)
    }
}
