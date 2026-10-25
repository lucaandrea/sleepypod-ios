import SwiftUI

struct RawDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: SleepExportWorkspace
    @State private var expanded = false
    @State private var deleting: RawSensorFile?
    private let backend: APIBackend
    private let side: Side
    private let start: Date
    private let end: Date
    private let vitals: [VitalsRecord]
    private let sleep: [SleepRecord]
    private let movement: [MovementRecord]
    private let reference: WatchReferenceData
    init(metrics: MetricsManager) {
        backend = APIBackend.current; side = metrics.selectedSide
        start = metrics.selectedWeekStart
        end = metrics.calendar.date(byAdding: .hour, value: 12, to: metrics.selectedWeekEnd) ?? metrics.selectedWeekEnd
        vitals = metrics.vitalsRecords; sleep = metrics.sleepRecords; movement = metrics.movementRecords
        reference = WatchReferenceData()
        _model = State(initialValue: SleepExportWorkspace(api: APIBackend.current.isDemo ? DemoRawDataClient() : CoreRawDataClient()))
    }
    init(side: Side, start: Date, end: Date, vitals: [VitalsRecord], sleep: [SleepRecord], movement: [MovementRecord], reference: WatchReferenceData = WatchReferenceData()) {
        backend = APIBackend.current; self.side = side; self.start = start; self.end = end
        self.vitals = vitals; self.sleep = sleep; self.movement = movement
        self.reference = reference
        _model = State(initialValue: SleepExportWorkspace(api: APIBackend.current.isDemo ? DemoRawDataClient() : CoreRawDataClient()))
    }
    private var dateRange: String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: SleepCalendar.calendar(timeZone: settings.timeZone).timeZone)
        return "\(start.formatted(format)) → \(end.formatted(format))"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(settings.sideName(for: side)).font(.headline)
                    Text(dateRange).font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Text(settings.timeZone).font(.footnote).foregroundStyle(Theme.text3)
                    VStack(spacing: 12) {
                        stat("Vitals", value: "\(vitals.count) readings")
                        stat("Sleep", value: "\(sleep.count) records")
                        stat("Movement", value: "\(movement.count) readings")
                    }.cardStyle()
                    VStack(alignment: .leading, spacing: 16) {
                        exportButton("Vitals CSV", count: vitals.count, filename: "vitals", content: SleepCSV.vitals(vitals))
                        exportButton("Sleep CSV", count: sleep.count, filename: "sleep", content: SleepCSV.sleep(sleep))
                        exportButton("Movement CSV", count: movement.count, filename: "movement", content: SleepCSV.movement(movement))
                        if reference.count > 0 { exportButton("Apple Watch reference CSV", count: reference.count, filename: "watch-reference", content: reference.csv) }
                        Button("Export all CSV files", systemImage: "square.and.arrow.up") {
                            var files = [(name: "vitals-\(side.rawValue).csv", text: SleepCSV.vitals(vitals)),
                                       (name: "sleep-\(side.rawValue).csv", text: SleepCSV.sleep(sleep)),
                                       (name: "movement-\(side.rawValue).csv", text: SleepCSV.movement(movement))]
                            if reference.count > 0 { files.append((name: "watch-reference-\(side.rawValue).csv", text: reference.csv)) }
                            model.csv(files)
                        }.disabled(vitals.isEmpty && sleep.isEmpty && movement.isEmpty)
                        Text("Missing readings stay blank. The three files keep their own columns and can be opened in Numbers or Excel.")
                            .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }.cardStyle().disabled(model.preparing)
                    if backend != .freeSleep { controllerFiles }
                    if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
                    if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                    if model.preparing {
                        ProgressView(model.activity)
                        if model.canCancel { Button("Cancel download") { model.cancel() } }
                    }
                }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
            }.background(Theme.background).navigationTitle("Raw data").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.cancel(); dismiss() } } }
            .sheet(isPresented: Binding(get: { !model.shares.isEmpty }, set: { if !$0 { model.cleanup() } })) { ShareSheet(items: model.shares) }
            .task { if backend != .freeSleep { await model.refresh() } }
            .onDisappear { model.cancel() }
            .confirmationDialog("Delete sensor file?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { file in
                Button("Delete \(file.name)", role: .destructive) { Task { await model.delete(file) } }
            } message: { file in Text("Permanently remove \(file.name) (\(file.size)) from the Pod. This file contains readings from both sides. This cannot be undone.") }
        }
    }
    private var controllerFiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let usage = model.usage {
                stat("Sensor files", value: "\(usage.rawFileCount)")
                stat("Sensor storage", value: ByteCountFormatter.string(fromByteCount: usage.rawBytes, countStyle: .file))
                if usage.availableBytes > 0 { stat("Available space", value: ByteCountFormatter.string(fromByteCount: usage.availableBytes, countStyle: .file)) }
            }
            if backend.isDemo { Text("DEMO · sensor files are simulated. CSV exports contain demo readings.").font(.footnote).foregroundStyle(Theme.text2) }
            Button("Export archive", systemImage: "archivebox") { model.archive(start: start, end: end) }.disabled(backend.isDemo || model.preparing)
            Text("Includes RAW waveforms in this interval and the full biometrics database for both sides. Large archives may take several minutes.")
                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Sensor data files", isExpanded: $expanded) {
                Text("All files on this Pod · both sides").font(.footnote).foregroundStyle(Theme.text2).padding(.vertical, 8)
                if model.loading { ProgressView("Loading files…") }
                if model.files.isEmpty && !model.loading && model.error == nil { Text("No sensor files found.").font(.footnote) }
                ForEach(model.files) { file in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file.name).font(.mono(15, relativeTo: .body))
                        Text("\(file.size)\(file.date.map { " · " + $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: SleepCalendar.calendar(timeZone: settings.timeZone).timeZone)) } ?? "")")
                            .font(.footnote).foregroundStyle(Theme.text2)
                        ViewThatFits(in: .horizontal) { fileActions(file, vertical: false); fileActions(file, vertical: true) }
                    }.padding(.vertical, 10)
                    if file.id != model.files.last?.id { Divider() }
                }
            }.accessibilityIdentifier("sleep.sensorFiles")
            Button("Refresh file list", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.loading || model.preparing)
        }.cardStyle()
    }
    private func fileActions(_ file: RawSensorFile, vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 20))
        return layout {
            Button("Download", systemImage: "arrow.down.circle") { model.download(file) }.disabled(backend.isDemo || model.preparing)
                .accessibilityLabel("Download \(file.name)")
            if file.name == model.files.first?.name { Text("Active file").font(.footnote).foregroundStyle(Theme.text3) }
            else { Button("Delete", systemImage: "trash", role: .destructive) { deleting = file }.disabled(model.preparing).accessibilityLabel("Delete \(file.name)") }
        }.font(.subheadline)
    }
    private func stat(_ title: String, value: String) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        return layout { Text(title).foregroundStyle(Theme.text2); if !typeSize.isAccessibilitySize { Spacer() }; Text(value).monospacedDigit() }.font(.subheadline)
    }
    private func exportButton(_ title: String, count: Int, filename: String, content: String) -> some View {
        Button { model.csv([(name: "\(filename)-\(side.rawValue).csv", text: content)]) } label: {
            Label("\(title) · \(count)", systemImage: "arrow.down.doc")
        }.disabled(count == 0)
    }
}

/// Load the selected night, week or month explicitly; never export an unrelated cached week.
struct SleepRangeExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let side: Side
    let window: DateInterval
    @State private var model = SleepRangeExportWorkspace(api: APIBackend.current.createClient())
    var body: some View {
        Group {
            if let result = model.result {
                RawDataSheet(side: side, start: result.window.start, end: result.window.end, vitals: result.vitals, sleep: result.sleep, movement: result.movement)
            } else {
                NavigationStack {
                    VStack(spacing: 20) {
                        if let error = model.error { Text(error).foregroundStyle(Theme.amber); Button("Retry") { Task { await load() } } }
                        else { ProgressView("Loading the selected range…") }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                        .navigationTitle("Raw data").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
            }
        }.task { await load() }
    }
    private func load() async { await model.load(side: side, nights: window) }
}
