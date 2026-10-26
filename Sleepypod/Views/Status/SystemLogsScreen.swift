import SwiftUI
import UniformTypeIdentifiers

struct SystemLogsScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SensorStreamService.self) private var sensor
    @State private var model: SystemLogWorkspace
    @State private var search = ""
    @State private var follow = true
    @State private var copied = false
    @State private var exporting = false
    @State private var exportDocument = SystemLogDocument(text: "")
    @State private var exportError: String?
    @FocusState private var searchFocused: Bool
    private struct Poll: Hashable { let query: SystemLogQuery; let active: Bool; let follow: Bool }

    init(unit: String? = nil, client: (any SystemLogClient)? = nil) {
        let chosen = client ?? (APIBackend.current.isDemo ? DemoSystemLogClient() : CoreSystemLogClient())
        _model = State(initialValue: SystemLogWorkspace(unit: unit, client: chosen))
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if APIBackend.current.isDemo { Text("DEMO · simulated service logs").font(.footnote).foregroundStyle(Theme.amber) }
                    controls
                    if let error = model.sourcesError { Text("Sources: \(error)").foregroundStyle(Theme.amber) }
                    if model.loadingSources && model.sources.isEmpty { ProgressView("Finding log sources…") }
                    if let error = model.error {
                        Text(error).foregroundStyle(Theme.amber)
                        if model.receivedAt != nil { Text("Showing the last successful snapshot. Copy and export are disabled until refresh succeeds.").font(.footnote).foregroundStyle(Theme.amber) }
                    }
                    if let exportError { Text(exportError).foregroundStyle(Theme.amber) }
                    if model.loading { ProgressView("Reading logs…") }
                    let entries = model.filtered(search)
                    Text("\(entries.count) matching \(entries.count == 1 ? "line" : "lines") · newest first").font(.footnote).accessibilityIdentifier("logs.count")
                    if let received = model.receivedAt { Text("Read \(received.formatted(date: .omitted, time: .standard)) · \(follow ? "Following" : "Paused")").font(.caption).foregroundStyle(Theme.text2) }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Color.clear.frame(height: 1).id("logs.newest")
                        ForEach(entries) { entry in row(entry) }
                    }
                    if entries.isEmpty, !model.loading { Text(model.query.unit == nil ? "No service selected." : "No matching log lines.").foregroundStyle(Theme.text2) }
                    if model.hasOlder { Text("Older entries exist. Increase the line limit to inspect more.").font(.caption).foregroundStyle(Theme.text2) }
                }.padding(16)
            }.accessibilityIdentifier("logs.content").background(Theme.background)
                .onChange(of: model.entries.map(\.raw)) { previous, current in
                    if follow, !previous.isEmpty, previous != current { proxy.scrollTo("logs.newest", anchor: .top) }
                    copied = false
                }
                .onChange(of: search) { _, _ in copied = false }
        }
        .navigationTitle("Logs").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button(follow ? "Pause" : "Follow") { follow.toggle() }.accessibilityIdentifier("logs.follow")
        } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            repeat {
                await model.loadSources()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .task(id: Poll(query: model.query, active: scenePhase == .active, follow: follow)) {
            guard scenePhase == .active, model.query.unit != nil else { return }
            if follow || model.receivedAt == nil { await model.load() }
            while follow && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await model.load()
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .plainText, defaultFilename: "\((model.query.unit ?? "sleepypod").replacingOccurrences(of: ".service", with: ""))-logs.log") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }
    private var controls: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source", selection: Binding(get: { model.query.unit }, set: { model.setUnit($0) })) {
                    if model.query.unit == nil { Text("Choose a source").tag(String?.none) }
                    ForEach(model.sources) { source in Text("\(source.name) · \(source.active ? "active" : "inactive")").tag(Optional(source.unit)) }
                }.accessibilityIdentifier("logs.source")
                Picker("Level", selection: Binding(get: { model.query.level }, set: { model.setLevel($0) })) {
                    ForEach(SystemLogLevel.allCases) { level in Text(level.title).tag(level) }
                }.accessibilityIdentifier("logs.level")
                Text("Level includes that priority and more severe entries.").font(.caption).foregroundStyle(Theme.text2)
                Picker("Line limit", selection: Binding(get: { model.query.lines }, set: { model.setLimit($0) })) {
                    ForEach([50, 100, 200, 500], id: \.self) { Text("\($0) lines").tag($0) }
                }
                TextField("Filter log text", text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }.accessibilityIdentifier("logs.search")
                Button("Refresh logs") { Task { await model.loadSources(); await model.load() } }.disabled(model.loading || model.loadingSources)
                Button(copied ? "Copied" : "Copy matching lines") {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": model.export(search)]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(600)])
                    copied = true
                }.disabled(model.error != nil || model.filtered(search).isEmpty).accessibilityIdentifier("logs.copy")
                Button("Export matching lines") {
                    exportDocument = SystemLogDocument(text: model.export(search)); exportError = nil; exporting = true
                }.disabled(model.error != nil || model.filtered(search).isEmpty).accessibilityIdentifier("logs.export")
                NavigationLink {
                    ScrollView {
                        FirmwareLogConsoleView(logs: sensor.firmwareLogs, recentFrames: sensor.recentFrames, onClear: { sensor.clearLogs() }).padding(16)
                    }.background(Theme.background).navigationTitle("Firmware console").task { sensor.connect() }
                } label: { Label("Firmware console", systemImage: "terminal") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func row(_ entry: SystemLogEntry) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(entry.time) · \(entry.level.title.uppercased())").font(.caption.monospaced()).foregroundStyle(color(entry.level))
                if !entry.service.isEmpty { Text(entry.service).font(.caption).foregroundStyle(Theme.text2) }
                Text(entry.message).font(.callout).textSelection(.enabled)
                if let json = entry.json {
                    DisclosureGroup("Structured data") { Text(json).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }
    private func color(_ level: SystemLogLevel) -> Color {
        switch level {
        case .error: Theme.red
        case .warning: Theme.amber
        case .debug: Theme.text2
        default: Theme.green
        }
    }
}

struct SystemLogDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
