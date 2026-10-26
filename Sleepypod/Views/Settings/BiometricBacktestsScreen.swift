import SwiftUI

struct BiometricBacktestsScreen: View {
    let side: Side
    @State private var model: BiometricDatasetWorkspace?
    @State private var error: String?
    @State private var demo = DemoBiometricDatasetsClient()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: side)
                Text("Retain recorded nights and reference revisions before preparing an evaluation. Saved inputs do not change the active profile.").font(.footnote).foregroundStyle(Theme.text2)
                if let model {
                    if APIBackend.current.isDemo { Text("Demo · bundled synthetic nights and references. Changes stay in memory; no evaluation or hardware operation is simulated.").font(.footnote).foregroundStyle(Theme.text2) }
                    BiometricBacktestPendingCard(model: model)
                    GroupedCard {
                        NavigationLink { BiometricDatasetBuilderScreen(model: model) } label: { SettingsRow("Freeze evaluation inputs", icon: "snowflake", tile: true, chevron: true) }.accessibilityIdentifier("backtests.createDataset")
                        NavigationLink { BiometricDatasetLibraryScreen(model: model) } label: { SettingsRow("Retained datasets", icon: "archivebox", tile: true, chevron: true) }.accessibilityIdentifier("backtests.datasets")
                    }
                } else if let error {
                    BiometricProfileError(error: error)
                    Button("Retry") { Task { configure() } }
                } else { ProgressView("Loading backtests…") }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Backtests").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("backtests.content")
            .task { if model == nil { configure() } }
    }
    private func configure() {
        do {
            let client: any BiometricDatasetsServing = APIBackend.current.isDemo ? demo : CoreBiometricDatasetsClient(transport: try .configured())
            let store = APIBackend.current.isDemo ? BiometricBacktestPendingStore(directory: nil) : try .persistent()
            model = .init(side: side, client: client, store: store); error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct BiometricBacktestPendingCard: View {
    let model: BiometricDatasetWorkspace
    @State private var confirmDiscard = false
    var body: some View {
        if model.pending != nil || model.unreadable || model.error != nil || model.notice != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.error { BiometricProfileError(error: error) }
                if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("backtests.notice") }
                if let pending = model.pending {
                    Text("Retained request").font(.headline)
                    switch pending {
                    case .dataset(let request):
                        Text("Dataset for \(request.subjectId). Sessions: \(request.sessionIds.count) · Reference revisions: \(request.referenceImportIds.count).")
                        Text("Retry uses the same saved key. If the controller already saved these inputs, it returns that dataset. A changed Pod timezone can cause a conflict.").font(.footnote).foregroundStyle(Theme.text2)
                        BiometricProfileIdentity(title: "Retry identity", value: request.idempotencyKey)
                    case .releaseDataset(let identity):
                        Text("Release retained dataset inputs")
                        BiometricProfileIdentity(title: "Dataset", value: identity.id)
                        BiometricProfileIdentity(title: "Content hash", value: identity.contentHash)
                        Button("Check release status") { Task { await model.inspectRelease() } }.disabled(model.busy)
                    }
                    Button("Retry exact request") { Task { await model.retry() } }.disabled(model.busy).accessibilityIdentifier("backtests.retry")
                }
                if model.pending != nil || model.unreadable {
                    Button("Stop retaining this request", role: .destructive) { confirmDiscard = true }.disabled(model.busy)
                }
                if model.busy { ProgressView("Waiting for the controller…") }
            }.cardStyle().confirmationDialog("Remove this local retry request? Any saved controller change remains.", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Remove local request", role: .destructive) { model.discardPending() }
            }
        }
    }
}

struct BiometricDatasetBuilderScreen: View {
    let model: BiometricDatasetWorkspace
    @State private var draft: BiometricDatasetDraft
    init(model: BiometricDatasetWorkspace) { self.model = model; _draft = State(initialValue: .init(side: model.side)) }
    var body: some View {
        @Bindable var draft = draft
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: model.side)
                Text("Retain copies of selected sessions and reference revisions. Later edits or source deletion do not alter a frozen dataset.").font(.footnote).foregroundStyle(Theme.text2)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sleeper identifier").font(.headline)
                    TextField("Sleeper identifier", text: $draft.subjectId).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).accessibilityIdentifier("datasets.subject")
                    if APIBackend.current.isDemo { Button("Use demo sleeper") { draft.subjectId = "demo-sleeper" }.accessibilityIdentifier("datasets.demoSleeper") }
                    Text("Changing the identifier clears selected references.").font(.footnote).foregroundStyle(Theme.text2)
                }.cardStyle()
                GroupedCard {
                    NavigationLink { ReplaySessionPickerScreen(client: model.client, draft: draft) } label: { SettingsRow("Recorded nights", icon: "moon", tile: true, chevron: true) }.accessibilityIdentifier("datasets.sessions")
                    NavigationLink { DatasetReferencePickerScreen(client: model.client, draft: draft) } label: { SettingsRow("Reference revisions", icon: "doc.text", tile: true, chevron: true) }.accessibilityIdentifier("datasets.references")
                }
                Text("\(draft.selectedSessions.count) / 60 sessions · \(draft.selectedReferences.count) / 20 reference revisions").font(.footnote).accessibilityIdentifier("datasets.selectionCount")
                if draft.selectedReferences.isEmpty { Text("No references selected. These inputs cannot establish agreement with reference measurements.").font(.footnote).foregroundStyle(Theme.text2) }
                Text("The controller groups connected sessions into whole nights in its timezone before assigning tuning, validation and holdout sets. A split does not establish improvement.").font(.footnote).foregroundStyle(Theme.text2)
                NavigationLink { BiometricDatasetReviewScreen(model: model, selection: draft.selection, sessions: draft.selectedSessions.values.map(\.session), references: Array(draft.selectedReferences.values)) } label: { Label("Review selected inputs", systemImage: "checklist") }.disabled(!draft.valid || !model.canMutate).accessibilityIdentifier("datasets.review")
                BiometricBacktestPendingCard(model: model)
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Evaluation inputs").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.builderContent")
    }
}

struct BiometricDatasetReviewScreen: View {
    let model: BiometricDatasetWorkspace
    let selection: BiometricDatasetSelection
    let sessions: [ReplaySession]
    let references: [ReferenceDescriptor]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: selection.side)
                BiometricProfileValue("Sleeper identifier", value: selection.subjectId)
                Text("Sessions: \(sessions.count) · Reference revisions: \(references.count)").font(.headline)
                ForEach(sessions.sorted { $0.startMs < $1.startMs }) { session in ReplaySessionSummary(session: session).cardStyle() }
                ForEach(references.sorted { $0.summary.source < $1.summary.source }) { reference in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(reference.summary.source) · revision \(reference.revision)").font(.headline)
                        Text(reference.summary.subjectId)
                        BiometricProfileIdentity(title: "Reference hash", value: reference.summary.contentHash)
                    }.cardStyle()
                }
                Text("The controller will copy the selected inputs as they exist when this request is saved. No evaluation runs and no profile changes.").font(.footnote).foregroundStyle(Theme.text2)
                Button("Freeze selected inputs") { Task { await model.create(selection) } }
                    .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                    .disabled(!model.canMutate || model.savedSelection == selection).accessibilityIdentifier("datasets.freeze")
                BiometricBacktestPendingCard(model: model)
                if let receipt = model.receipt, model.savedSelection == selection {
                    NavigationLink { BiometricDatasetDetailScreen(model: model, id: receipt.id) } label: { Label("Inspect saved dataset", systemImage: "archivebox") }.accessibilityIdentifier("datasets.inspectSaved")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Review inputs").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.reviewContent")
    }
}
