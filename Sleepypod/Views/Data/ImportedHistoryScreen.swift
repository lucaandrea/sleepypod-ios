import SwiftUI

private struct ImportedPresenceSelection: Identifiable {
    var id: Int { record.id }
    let record: ImportedPresenceRecord
    let snapshot: ImportedHistorySnapshot
}

struct ImportedHistoryScreen: View {
    @Environment(\.scenePhase) private var phase
    @State private var model = ImportedHistoryWorkspace()
    @State private var side: Side
    @State private var kind: ImportedHistoryKind = .presence
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var selection: ImportedPresenceSelection?
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    private var scope: String { "\(backend)|\(address)|\(host)|\(ownerRevision)|\(phase)" }
    private var zone: TimeZone { model.status?.snapshot.flatMap { TimeZone(identifier: $0.timeZone) } ?? .gmt }
    init(side: Side) { _side = State(initialValue: side) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if APIBackend.current.isDemo {
                    Eyebrow(DebugRoute.historyScenario == "empty" ? "DEMO · NO IMPORTED ARCHIVE" : "SYNTHETIC EXAMPLE · NOT PERSONAL DATA", color: Theme.amber)
                }
                Text("Earlier measurements, preserved with their original source.").foregroundStyle(Theme.text2)
                if model.busy { ProgressView("Reading imported history…") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("history.error") }
                if let status = model.status {
                    if let snapshot = status.snapshot {
                        ImportedHistorySourceCard(snapshot: snapshot)
                        filters(snapshot)
                        records(snapshot)
                    } else {
                        ContentUnavailableView(status.status == .notImported ? "No imported history" : "Archive unavailable", systemImage: "archivebox", description: Text(status.message))
                    }
                }
                Button("Reload archive") { Task { await reload() } }.disabled(model.busy).accessibilityIdentifier("history.reload")
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("history.scroll").background(Theme.background)
            .navigationTitle("Imported history").navigationBarTitleDisplayMode(.inline)
            .environment(\.timeZone, zone)
            .task(id: scope) {
                selection = nil
                guard phase == .active else { model.configure(client: nil); return }
                let client: (any ImportedHistoryClient)? = APIBackend.current.isDemo
                    ? DemoImportedHistoryClient(scenario: DebugRoute.historyScenario)
                    : (try? CoreRESTClient.configured()).map { CoreImportedHistoryClient(transport: $0) }
                model.configure(client: client); await reload()
            }
            .onDisappear { model.cancelPending() }
            .sheet(item: $selection) { item in
                if let client = model.client {
                    NavigationStack { ImportedPresenceScreen(client: client, snapshot: item.snapshot, record: item.record) }
                        .tint(Theme.text1)
                }
            }
    }
    private func reload() async {
        await model.loadStatus()
        guard let snapshot = model.status?.snapshot else { return }
        let latest = snapshot.bounds(side: side, kind: kind).lastAt
            ?? Side.allCases.flatMap { side in ImportedHistoryKind.allCases.compactMap { snapshot.bounds(side: side, kind: $0).lastAt } }.max()
        end = Date(timeIntervalSince1970: latest ?? snapshot.importedAt / 1000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
    }
    private func filterBinding<Value>(_ value: Binding<Value>) -> Binding<Value> {
        Binding(get: { value.wrappedValue }, set: { newValue in value.wrappedValue = newValue; model.clearRecords() })
    }
    private func filters(_ snapshot: ImportedHistorySnapshot) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Browse records").font(.headline)
                Picker("Historical side", selection: filterBinding($side)) { Text("Left").tag(Side.left); Text("Right").tag(Side.right) }
                    .pickerStyle(.segmented).accessibilityIdentifier("history.side")
                Picker("Record type", selection: filterBinding($kind)) { ForEach(ImportedHistoryKind.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.menu).accessibilityIdentifier("history.kind")
                VStack(alignment: .leading) {
                    Text("From").font(.subheadline).foregroundStyle(Theme.text2)
                    DatePicker("From", selection: filterBinding($start), in: Date(timeIntervalSince1970: 0)..., displayedComponents: .date)
                        .labelsHidden().accessibilityIdentifier("history.from")
                    Text("Through").font(.subheadline).foregroundStyle(Theme.text2)
                    DatePicker("Through", selection: filterBinding($end), in: Date(timeIntervalSince1970: 0)..., displayedComponents: .date)
                        .labelsHidden().accessibilityIdentifier("history.through")
                }
                Text("Inclusive dates · \(snapshot.timeZone) · up to 90 days").font(.caption).foregroundStyle(Theme.text2)
                let bounds = snapshot.bounds(side: side, kind: kind)
                Text("\(bounds.readableRecords.formatted()) readable of \(bounds.records.formatted()) archived \(kind.title.lowercased()) records on this side.").font(.footnote).foregroundStyle(Theme.text2)
                Button("View records") { Task { await model.apply(side: side, kind: kind, start: start, end: end) } }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(model.busy).accessibilityIdentifier("history.apply")
            }.padding(16)
        }
    }
    @ViewBuilder private func records(_ snapshot: ImportedHistorySnapshot) -> some View {
        if let applied = model.applied {
            Text("\(applied.side.displayName) · \(applied.kind.title)").font(.title3.bold())
            Text(ImportedHistoryDisplay.meaning(applied.kind)).font(.footnote).foregroundStyle(Theme.text2)
            if model.stale { Text("Previously loaded records · reload before continuing.").font(.footnote).foregroundStyle(Theme.amber) }
            if model.records.isEmpty { Text("No records in these dates.").foregroundStyle(Theme.text2).accessibilityIdentifier("history.emptyRange") }
            LazyVStack(spacing: 12) {
                ForEach(model.records) { item in
                if case .presence(let record) = item {
                    Button { selection = .init(record: record, snapshot: snapshot) } label: {
                        ImportedHistoryRecordCard(record: item, zone: zone)
                    }.buttonStyle(.plain).disabled(model.stale).accessibilityIdentifier("history.presence.\(record.id)")
                    } else { ImportedHistoryRecordCard(record: item, zone: zone) }
                }
            }
            if model.records.count >= 5_000, model.nextCursor != nil {
                Text("Showing 5,000 records. Choose fewer dates to inspect the rest.").font(.footnote).foregroundStyle(Theme.text2)
            } else if model.nextCursor != nil {
                Button("Load more records") { Task { await model.loadMore() } }.disabled(!model.canLoadMore).accessibilityIdentifier("history.more")
            }
        }
    }
}

struct ImportedHistorySourceCard: View {
    let snapshot: ImportedHistorySnapshot
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Archived Free Sleep measurements", systemImage: "archivebox").font(.headline)
                Text("Read-only history. These records do not count toward Preview qualification or control the bed.").font(.footnote).foregroundStyle(Theme.text2)
                DisclosureGroup("Source details") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Imported \(ImportedHistoryDisplay.date(snapshot.importedAt / 1000, zone: TimeZone(identifier: snapshot.timeZone) ?? .gmt))")
                        Text("Original timezone: \(snapshot.timeZone)")
                        Text("\(snapshot.unassignedRecords.formatted()) records have no assigned side.")
                        Text("Original database SHA-256").font(.caption).foregroundStyle(Theme.text2)
                        Text(snapshot.sourceSha256).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Archive identity").font(.caption).foregroundStyle(Theme.text2)
                        Text(snapshot.snapshotId).font(.caption.monospaced()).textSelection(.enabled)
                    }.font(.footnote).padding(.top, 8)
                }
            }.padding(16)
        }
    }
}

struct ImportedHistoryRecordCard: View {
    let record: ImportedHistoryRecord
    let zone: TimeZone
    var showDisclosure = true
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(ImportedHistoryDisplay.date(record.timestamp, zone: zone)).font(.headline)
                switch record {
                case .presence(let value):
                    ComfortValueRow("Left bed", value: ImportedHistoryDisplay.date(value.leftBedAt, zone: zone))
                    ComfortValueRow("Reported duration", value: ImportedHistoryDisplay.number(value.reportedDurationSeconds, unit: "s"))
                    ComfortValueRow("Reported exits", value: ImportedHistoryDisplay.number(value.exits))
                    if showDisclosure { Label("Presence details", systemImage: "chevron.right").font(.footnote).foregroundStyle(Theme.text2) }
                case .vitals(let value):
                    ComfortValueRow("Heart rate", value: ImportedHistoryDisplay.number(value.heartRateBpm, unit: "bpm"))
                    ComfortValueRow("HRV estimate", value: ImportedHistoryDisplay.number(value.hrvEstimateMs, unit: "ms"))
                    ComfortValueRow("Breathing", value: ImportedHistoryDisplay.number(value.breathingRatePerMinute, unit: "br/min"))
                case .movement(let value):
                    ComfortValueRow("Original total", value: ImportedHistoryDisplay.number(value.totalMovement))
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("history.record.\(record.id)")
    }
}

enum ImportedHistoryDisplay {
    static func date(_ seconds: Double, zone: TimeZone) -> String {
        Date(timeIntervalSince1970: seconds).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
    }
    static func number(_ value: Double?, unit: String = "") -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...2))) + (unit.isEmpty ? "" : " " + unit) } ?? "Unavailable"
    }
    static func meaning(_ kind: ImportedHistoryKind) -> String {
        switch kind {
        case .presence: "Bed presence, not measured sleep or sleep stages. Reported durations and exits retain their original values."
        case .vitals: "Five-minute averages, labelled by interval start. The original HRV estimator is unverified; it is not identified as Apple Health SDNN."
        case .movement: "Original movement totals. Their scale is retained; missing readings are unavailable."
        }
    }
}
