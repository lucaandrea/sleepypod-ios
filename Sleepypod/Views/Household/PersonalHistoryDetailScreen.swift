import SwiftUI

struct PersonalHistoryDetailScreen: View {
    let model: PersonalHistoryWorkspace
    let recordId: String
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            if model.busy { Section { ProgressView("Loading recording…") } }
            if let error = model.error { Section { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("history.detailError") } }
            if let detail = model.detail, detail.record.id == recordId {
                let record = detail.record
                Section("Complete recording") {
                    row("Started", PersonalHistoryPresentation.date(record.startsAt))
                    row("Ended", PersonalHistoryPresentation.date(record.endsAt))
                    Text("Times shown in \(TimeZone.current.identifier).").font(.caption).foregroundStyle(Theme.text2)
                    if let query = model.query, record.startsAt < query.startsAt || record.endsAt > query.endsAt {
                        Text("This recording extends beyond the selected range. Its full interval and values are shown.")
                            .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("history.fullInterval")
                    }
                }
                Section(record.payload.kind.title) { PersonalHistoryPayloadView(payload: record.payload) }
                Section("Source and attribution") {
                    row("Source", "Pod")
                    row("Recorded side", record.recordedSide.rawValue.capitalized)
                    row("Arrangement", PersonalHistoryPresentation.mode(record.attribution.mode))
                    row("Attribution", record.attribution.basis == .legacyReview ? "Reviewed legacy recording" : "Verified arrangement")
                    Text("Attribution follows the reviewed arrangement when this recording was made. It is not biometric identification and does not change when your current side changes.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                    Text("This recording is not confirmed sleep. It is not exported to Apple Health.")
                        .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("history.detailMeaning")
                }
            }
        }
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Recording").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Reload recording", systemImage: "arrow.clockwise") { Task { await model.loadDetail(recordId) } }
                .disabled(model.busy || !model.enabled)
        } }
        .task { await model.loadDetail(recordId) }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.loadDetail(recordId) } }
            else { model.suspend() }
        }
        .onDisappear { model.clearDetail() }
    }
    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}
