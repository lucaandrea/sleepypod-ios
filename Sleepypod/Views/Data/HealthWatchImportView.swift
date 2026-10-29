import SwiftUI

struct HealthWatchImportView: View {
    @Environment(HealthSyncService.self) private var health
    @Environment(SettingsManager.self) private var settings
    @State private var model: HealthWatchImportWorkspace
    @State private var operation: Task<Void, Never>?
    @State private var review = false
    private let onImported: () async -> Void

    init(side: Side, onImported: @escaping () async -> Void = {}) {
        let transport = APIBackend.current.isDemo ? nil : try? CoreRESTClient.configured()
        _model = State(initialValue: HealthWatchImportWorkspace(side: side, writer: transport.map(CoreHealthWatchReferenceWriter.init)))
        self.onImported = onImported
    }
    private var busy: Bool { model.reading || model.importing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Watch references", systemImage: "applewatch").font(.headline)
                    Text("Read permitted Watch sleep stages, heart rate, breathing rate and SDNN HRV from Apple Health, then review the import.")
                    Text("Samples go only to your Pod and stay separate from its measurements. Importing does not change temperature or activate a model.")
                    Text("\(settings.sideName(for: model.side)) · \(model.side.rawValue) side\nDestination: \(model.destination)")
                        .font(.footnote).foregroundStyle(Theme.text2).textSelection(.enabled)
                }.cardStyle()
                VStack(alignment: .leading, spacing: 12) {
                    Picker("History period", selection: $model.period) {
                        ForEach(WatchImportPeriod.allCases) { Text($0.title).tag($0) }
                    }.disabled(busy)
                    Button("Read Apple Watch history", systemImage: "heart.text.clipboard") {
                        operation = Task { await model.prepare(health: health) }
                    }.disabled(busy || model.writer == nil).accessibilityIdentifier("watch.readHealth")
                    if model.reading { ProgressView("Reading permitted Watch samples…") }
                    if let snapshot = model.snapshot {
                        Text("\(snapshot.stages.count) stage segments · \(snapshot.heart.count) heart-rate samples\n\(snapshot.breathing.count) breathing samples · \(snapshot.hrv.count) SDNN HRV samples")
                            .accessibilityIdentifier("watch.healthReviewCounts")
                        Text("\(snapshot.excluded) unsupported, conflicting or out-of-range Watch records excluded.").font(.footnote).foregroundStyle(Theme.text2)
                        if snapshot.count == 0 {
                            Text("No readable Watch samples in this period. Check Health permissions and the selected dates; Apple does not disclose whether read access was denied.").font(.footnote)
                        }
                        Button("Review import", systemImage: "arrow.up.doc") { review = true }
                            .disabled(busy || snapshot.count == 0).accessibilityIdentifier("watch.reviewHealthImport")
                    }
                }.cardStyle()
                if model.importing {
                    ProgressView(value: Double(model.processed), total: Double(max(1, model.snapshot?.count ?? 1)))
                    Text("\(model.processed) records processed · \(model.written) newly stored")
                }
                if busy { Button("Cancel") { operation?.cancel() } }
                if model.complete {
                    Label("Import complete · \(model.written) new records", systemImage: "checkmark.circle").foregroundStyle(Theme.green)
                    Text("Previously imported records were skipped. Watch references are now available for comparison and model validation on this Pod.").font(.footnote)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }.frame(maxWidth: 680).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Import from Health").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(busy).interactiveDismissDisabled(busy)
            .onChange(of: model.period) { model.reset() }
            .confirmationDialog("Import Watch references?", isPresented: $review, titleVisibility: .visible) {
                Button("Import to this Pod") {
                    operation = Task {
                        await model.send(health: health)
                        if model.complete { await onImported() }
                    }
                }
            } message: {
                Text("Send \(model.snapshot?.count ?? 0) reviewed samples to \(model.destination), assigned to \(settings.sideName(for: model.side)) (\(model.side.rawValue)). Existing references are preserved.")
            }
            .onDisappear { operation?.cancel(); if !busy { model.reset() } }
    }
}
