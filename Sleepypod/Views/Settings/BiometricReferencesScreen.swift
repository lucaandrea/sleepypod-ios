import SwiftUI

struct BiometricReferencesScreen: View {
    let side: Side
    @State private var model: BiometricReferencesWorkspace?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let model { ReferenceLibraryContent(model: model) }
                else if let error { BiometricProfileError(error: error); Button("Retry") { configure(); Task { await model?.load() } } }
                else { ProgressView("Loading references…") }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("References").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("references.content")
            .task { if model == nil { configure() }; if let model { await model.load(model.cursor) } }
    }
    private func configure() {
        do {
            let client: any BiometricReferencesServing = APIBackend.current.isDemo ? DemoBiometricReferencesClient() : CoreBiometricReferencesClient(transport: try .configured())
            model = BiometricReferencesWorkspace(side: side, client: client, store: APIBackend.current.isDemo ? .init(directory: nil) : try .persistent())
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct ReferenceLibraryContent: View {
    let model: BiometricReferencesWorkspace
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ReferenceSideValue(side: model.side)
            Text("Import measurements from a reference source for later comparison. A saved import does not establish validation.").font(.footnote).foregroundStyle(Theme.text2)
            if APIBackend.current.isDemo { Text("Demo · bundled synthetic measurements only. Changes stay in this workspace.").font(.footnote).foregroundStyle(Theme.text2) }
            NavigationLink { ReferenceImportScreen(model: model) } label: { Label("Import reference measurements", systemImage: "plus") }
                .disabled(!model.canMutate).accessibilityIdentifier("references.new")
            ReferencePendingCard(model: model)
            if let receipt = model.receipt {
                NavigationLink("Inspect last saved result") { ReferenceDetailScreen(model: model, initial: receipt) }.accessibilityIdentifier("references.receipt")
            }
            Button("Reload library", systemImage: "arrow.clockwise") { Task { await model.load() } }.disabled(model.loading).accessibilityIdentifier("references.reload")
            if model.loading { ProgressView("Loading references…") }
            if let error = model.loadError { BiometricProfileError(error: error) }
            if let page = model.page {
                if page.items.isEmpty { Text("No reference imports for this side.").foregroundStyle(Theme.text2) }
                ForEach(page.items) { descriptor in
                    NavigationLink { ReferenceDetailScreen(model: model, initial: descriptor) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(descriptor.summary.source).font(.headline)
                            Text("\(descriptor.summary.subjectId) · revision \(descriptor.revision)").foregroundStyle(Theme.text2)
                            Text(descriptor.available ? "\(descriptor.summary.accepted) measurements" : "Source deleted").font(.footnote)
                            BiometricProfileDate(title: "Imported", milliseconds: descriptor.createdAtMs)
                        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }.buttonStyle(.plain).accessibilityIdentifier("references.item.\(descriptor.id)")
                }
                if !model.previous.isEmpty { Button("Newer imports") { Task { await model.load(model.previous.last ?? nil, direction: -1) } }.disabled(model.loading) }
                if let next = page.nextCursor { Button("Older imports") { Task { await model.load(next, direction: 1) } }.disabled(model.loading) }
            }
        }
    }
}

struct ReferencePendingCard: View {
    let model: BiometricReferencesWorkspace
    @State private var confirmStop = false
    var body: some View {
        if model.pending != nil || model.unreadable || model.error != nil || model.notice != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.error { BiometricProfileError(error: error) }
                if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("references.notice") }
                if let pending = model.pending {
                    Text("Retained request").font(.headline)
                    switch pending {
                    case .commit(let request):
                        Text("Import · \(request.input.source) · \(request.input.subjectId)")
                        BiometricProfileIdentity(title: "Reviewed content", value: request.previewHash)
                    case .deletion(let descriptor): Text("Delete · \(descriptor.summary.source) · revision \(descriptor.revision)")
                    }
                    Text("No automatic retry. Inspect the saved result before repeating this exact request.").font(.footnote).foregroundStyle(Theme.text2)
                    Button("Check saved result") { Task { await model.inspectPending() } }.disabled(model.busy)
                    if model.canRetry { Button("Retry exact request") { Task { await model.retry() } }.disabled(model.busy) }
                }
                if model.pending != nil || model.unreadable { Button("Stop retaining this request", role: .destructive) { confirmStop = true }.disabled(model.busy) }
                if model.busy { ProgressView("Checking reference request…") }
            }.cardStyle()
                .confirmationDialog("Remove the local retained request?", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Remove local request", role: .destructive) { model.stopRetrying() }
                } message: { Text("This does not undo any controller change. Inspect the library before preparing another import.") }
        }
    }
}

struct ReferenceSummaryCard: View {
    let summary: ReferencePreview
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import summary").font(.headline)
            ReferenceSideValue(side: summary.side)
            BiometricProfileValue("Source", value: summary.source)
            BiometricProfileValue("Sleeper identifier", value: summary.subjectId)
            Text("\(summary.received) received · \(summary.accepted) accepted · \(summary.rejected) rejected").font(.subheadline).accessibilityIdentifier("references.counts")
            Text("\(summary.duplicates) duplicates · \(summary.unscorable) excluded from scoring · \(summary.conflicts) stage conflicts").font(.footnote).foregroundStyle(Theme.text2)
            ForEach(summary.metrics, id: \.self) { Text(ReferenceLabels.metric($0)).font(.subheadline) }
            if let start = summary.startMs { BiometricProfileDate(title: "First measurement", milliseconds: start) }
            if let end = summary.endMs { BiometricProfileDate(title: "Last measurement", milliseconds: end) }
            Text("First-to-last extent, not continuous coverage. Dates use your Pod’s timezone.").font(.caption).foregroundStyle(Theme.text2)
            if !summary.rejectionCounts.isEmpty {
                DisclosureGroup("Rejected rows") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(summary.rejectionCounts.keys.sorted(), id: \.self) { key in Text("\(key): \(summary.rejectionCounts[key] ?? 0)").font(.caption.monospaced()) }
                        ForEach(Array(summary.rejectionExamples.enumerated()), id: \.offset) { _, rejection in
                            Text("Row \(rejection.row): \(rejection.message)").font(.footnote)
                        }
                    }.padding(.top, 8)
                }.accessibilityIdentifier("references.rejections")
            }
            ForEach(summary.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.text2) }
            DisclosureGroup("Import identity and time interpretation") {
                VStack(alignment: .leading, spacing: 8) {
                    BiometricProfileIdentity(title: "Content hash", value: summary.contentHash)
                    BiometricProfileValue("Adapter", value: summary.adapterVersion)
                    BiometricProfileValue("Ambiguous local times", value: summary.timePolicy.disambiguation)
                    if let timezone = summary.timePolicy.timezone { BiometricProfileValue("Timezone policy", value: timezone) }
                    if let offset = summary.timePolicy.utcOffsetMinutes { BiometricProfileValue("UTC offset policy", value: "\(offset) minutes") }
                }.padding(.top, 8)
            }
        }.cardStyle()
    }
}

struct ReferenceSideValue: View {
    @Environment(SettingsManager.self) private var settings
    let side: Side
    private var name: String {
        let sleeper = settings.sideName(for: side)
        return sleeper.lowercased() == side.rawValue ? side.rawValue.capitalized : "\(side.rawValue.capitalized) · \(sleeper)"
    }
    var body: some View { BiometricProfileValue("Bed side", value: name) }
}
