import SwiftUI

struct ImportedPresenceScreen: View {
    let client: any ImportedHistoryClient
    let snapshot: ImportedHistorySnapshot
    let record: ImportedPresenceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var model = ImportedPresenceWorkspace()
    private var zone: TimeZone { TimeZone(identifier: snapshot.timeZone) ?? .gmt }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(record.side.displayName) · \(snapshot.timeZone)").font(.footnote).foregroundStyle(Theme.text2)
                ImportedHistoryRecordCard(record: .presence(record), zone: zone, showDisclosure: false)
                Text("Presence describes time in bed, not measured sleep. Present and absent intervals are independent source claims; they may conflict or leave gaps.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if model.busy { ProgressView("Reading presence details…") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber) }
                if let detail = model.detail {
                    ImportedIntervalsCard(title: "Present intervals", value: detail.present, zone: zone)
                    ImportedIntervalsCard(title: "Absent intervals", value: detail.absent, zone: zone)
                    originalText(detail)
                }
                Button("Reload presence details") { Task { await load() } }.disabled(model.busy)
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("history.presence.scroll").background(Theme.background)
            .navigationTitle("Presence record").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }.onDisappear { model.invalidate() }
    }
    private func load() async { await model.load(client: client, snapshotID: snapshot.snapshotId, record: record) }
    private func originalText(_ detail: ImportedHistoryDetail) -> some View {
        GroupedCard {
            DisclosureGroup("Original interval text") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("The source text is preserved independently of the normalized intervals above.").font(.footnote).foregroundStyle(Theme.text2)
                    raw("Present", value: detail.rawPresentIntervals)
                    raw("Absent", value: detail.rawAbsentIntervals)
                }.padding(.top, 10)
            }.padding(16)
        }
    }
    @ViewBuilder private func raw(_ title: String, value: String?) -> some View {
        Text(title).font(.headline)
        if let value {
            Text(String(value.prefix(4_000))).font(.caption.monospaced()).textSelection(.enabled)
            if value.count > 4_000 { Text("Showing the first 4,000 characters. Copy includes all original text.").font(.caption).foregroundStyle(Theme.text2) }
            Button("Copy \(title.lowercased()) interval text", systemImage: "doc.on.doc") { UIPasteboard.general.string = value }
        } else { Text("Original text unavailable").font(.footnote).foregroundStyle(Theme.text2) }
    }
}

private struct ImportedIntervalsCard: View {
    let title: String
    let value: ImportedHistoryIntervals
    let zone: TimeZone
    @State private var page = 0
    private let pageSize = 50
    private var intervals: [[Double]] { value.intervals ?? [] }
    private var lower: Int { min(page * pageSize, intervals.count) }
    private var upper: Int { min(lower + pageSize, intervals.count) }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(statusText).font(.footnote).foregroundStyle(Theme.text2)
                if value.status == .available {
                    ComfortValueRow("Covered time", value: ImportedHistoryDisplay.number(value.coveredSeconds, unit: "s"))
                    Text("Intervals \(lower + 1)–\(upper) of \(intervals.count)").font(.caption).foregroundStyle(Theme.text2)
                    ForEach(lower..<upper, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ImportedHistoryDisplay.date(intervals[index][0], zone: zone))
                            Text("to \(ImportedHistoryDisplay.date(intervals[index][1], zone: zone))").foregroundStyle(Theme.text2)
                        }.font(.footnote).padding(.vertical, 4)
                    }
                    if lower > 0 { Button("Previous intervals") { page -= 1 } }
                    if upper < intervals.count { Button("Next intervals") { page += 1 } }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var statusText: String {
        switch value.status {
        case .available: "Overlapping source intervals are combined and clipped to this record's window."
        case .unavailable: "No readable interval evidence. This is not a measured zero."
        case .invalid: "The original interval format could not be interpreted."
        case .tooLarge: "The original interval text exceeds the supported size."
        case .unsupportedWindow: "Interval inspection is limited to records spanning 72 hours or less."
        }
    }
}
