import SwiftUI

struct WaveformDatasetScreen: View {
    let model: BiometricDatasetWorkspace
    @State private var workspace: WaveformSelectionWorkspace
    @State private var night: String
    @State private var review: WaveformDatasetRequest?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase
    init(model: BiometricDatasetWorkspace, parent: BiometricDataset) {
        self.model = model
        _workspace = State(initialValue: .init(parent: parent, client: model.client))
        _night = State(initialValue: parent.manifest.splitProtocol.assignments.first?.cohortId ?? "")
    }
    private var cohort: BiometricDatasetManifest.Cohort? { workspace.draft.parent.manifest.splitProtocol.assignments.first { $0.cohortId == night } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Select archives for every frozen night, including five minutes of pre-roll. Archive bounds do not prove continuous coverage. The controller verifies and copies selected bytes before publishing a new dataset.").font(.footnote).foregroundStyle(Theme.text2)
                if APIBackend.current.isDemo { Text("Demo · synthetic metadata only. No RAW files are read or retained.").font(.footnote).foregroundStyle(Theme.text2) }
                BiometricBacktestPendingCard(model: model)
                if let error { BiometricProfileError(error: error) }
                WaveformAdmissionCard(workspace: workspace)
                if let cohort {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Archive scan").font(.headline)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Button("Inspect next archive") { Task { await workspace.inspectNext(cohort: cohort) } }
                                .disabled(!workspace.canInspect() || !model.canMutate).accessibilityIdentifier("waveforms.inspectNext")
                        }
                        Button("Restart archive scan") { workspace.restartScan() }.disabled(workspace.scanning || !model.canMutate)
                        if workspace.scanning { ProgressView("Inspecting the archive…") }
                        if let notice = workspace.scanNotice { Text(notice).font(.footnote).accessibilityIdentifier("waveforms.scanNotice") }
                        if let error = workspace.scanError { BiometricProfileError(error: error) }
                    }.cardStyle()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Frozen night").font(.headline)
                        Picker("Frozen night", selection: $night) {
                            ForEach(workspace.draft.parent.manifest.splitProtocol.assignments) { item in
                                Text(item.nightLabels.joined(separator: ", ")).tag(item.cohortId)
                            }
                        }.pickerStyle(.menu).disabled(workspace.scanning || !model.canMutate).accessibilityIdentifier("waveforms.night")
                        Text("\(workspace.draft.selected[night]?.count ?? 0) / 64 archives selected").font(.footnote)
                        Button("Clear this night’s selection", role: .destructive) { workspace.draft.clear(night) }.disabled(workspace.scanning || !model.canMutate)
                        BiometricProfileValue("Search begins · UTC", value: ReferenceLabels.utc(max(0, cohort.startMs - 300000)))
                        BiometricProfileValue("Search ends · UTC", value: ReferenceLabels.utc(cohort.endMs))
                    }.cardStyle()
                    if let error = workspace.sourceError { BiometricProfileError(error: error) }
                    if workspace.loadingSources { ProgressView("Loading inspected archives…") }
                    Button("Reload archive page", systemImage: "arrow.clockwise") { Task { await workspace.loadSources(cohort: cohort, cursor: workspace.sourceCursor) } }.disabled(workspace.loadingSources || workspace.scanning)
                    if let sources = workspace.sources, workspace.sourceCohortId == night {
                        if sources.items.isEmpty { Text("No inspected archives overlap this night. Inspect archives first.").foregroundStyle(Theme.text2) }
                        ForEach(sources.items) { source in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(source.inspection.sourceName).font(.headline).textSelection(.enabled)
                                Text(source.availability == "unavailable" ? "Source unavailable" : "Requires re-verification").font(.footnote).foregroundStyle(Theme.text2)
                                Text("Compressed bytes: \(source.inspection.artifact.compressedBytes)").font(.footnote)
                                if let first = source.inspection.inventory.firstEventMs { BiometricProfileValue("First event · UTC", value: ReferenceLabels.utc(first)) }
                                if let last = source.inspection.inventory.lastEventMs { BiometricProfileValue("Last event · UTC", value: ReferenceLabels.utc(last)) }
                                let selected = workspace.draft.selected[night]?[source.id] != nil
                                Button(selected ? "Remove archive" : "Include archive") {
                                    do { try workspace.draft.toggle(source, cohort: cohort); error = nil } catch { self.error = error.localizedDescription }
                                }.disabled(!model.canMutate || workspace.scanning || (!selected && (!source.selectable || (workspace.draft.selected[night]?.count ?? 0) >= 64))).accessibilityIdentifier("waveforms.select.\(source.id)")
                                NavigationLink { RawSourceInspectionScreen(source: source) } label: { Label("Inspection details", systemImage: "waveform") }.accessibilityIdentifier("waveforms.source.\(source.id)")
                            }.cardStyle()
                        }
                        if workspace.sourceCursor != nil { Button("First archive page") { Task { await workspace.loadSources(cohort: cohort) } }.disabled(workspace.loadingSources || workspace.scanning) }
                        if let next = sources.nextCursor { Button("Next archive page") { Task { await workspace.loadSources(cohort: cohort, cursor: next) } }.disabled(workspace.loadingSources || workspace.scanning) }
                    }
                    Button("Review waveform selection") {
                        do { review = try workspace.draft.request(); error = nil } catch { self.error = error.localizedDescription }
                    }.disabled(!workspace.draft.complete || !model.canMutate || workspace.scanning).accessibilityIdentifier("waveforms.review")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Retain waveforms").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("waveforms.content")
            .navigationDestination(item: $review) { request in WaveformSelectionReviewScreen(model: model, request: request, draft: workspace.draft) }
            .task(id: night) { if let cohort { await workspace.loadSources(cohort: cohort) } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await workspace.refreshAdmission()
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
    }
}

struct WaveformAdmissionCard: View {
    let workspace: WaveformSelectionWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replay resources").font(.headline)
            if let error = workspace.admissionError { BiometricProfileError(error: error) }
            if workspace.refreshingAdmission && workspace.admission == nil { ProgressView("Checking resource admission…") }
            if let admission = workspace.admission {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let fresh = workspace.admissionAt.map { (0...15).contains(Date.now.timeIntervalSince($0)) } ?? false
                    Text(!fresh || workspace.admissionError != nil ? "Resource status needs refresh" : admission.admitted ? "Archive work admitted at the last check" : "New archive work is currently deferred")
                }
                ForEach(admission.reasons, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).font(.footnote).foregroundStyle(Theme.text2) }
                if let qualification = admission.qualificationId { DisclosureGroup("Admission policy") { BiometricProfileIdentity(title: "Qualification identity", value: qualification) } }
            }
            Button("Refresh resource status") { Task { await workspace.refreshAdmission() } }.disabled(workspace.refreshingAdmission)
        }.cardStyle()
    }
}

struct WaveformSelectionReviewScreen: View {
    let model: BiometricDatasetWorkspace
    let request: WaveformDatasetRequest
    let draft: WaveformDatasetDraft
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: draft.parent.side)
                if APIBackend.current.isDemo { Text("Demo · synthetic metadata only. No RAW files are read or retained.").font(.footnote).foregroundStyle(Theme.text2) }
                BiometricProfileIdentity(title: "Parent dataset", value: request.parentDatasetId)
                BiometricProfileIdentity(title: "Parent hash", value: request.expectedContentHash)
                ForEach(request.cohorts, id: \.cohortId) { selected in
                    VStack(alignment: .leading, spacing: 10) {
                        let cohort = draft.parent.manifest.splitProtocol.assignments.first { $0.cohortId == selected.cohortId }
                        Text(cohort?.nightLabels.joined(separator: ", ") ?? selected.cohortId).font(.headline)
                        Text("Selected archives: \(selected.sourceIds.count)").font(.footnote)
                        ForEach(selected.sourceIds, id: \.self) { identifier in
                            BiometricProfileIdentity(title: draft.selected[selected.cohortId]?[identifier]?.inspection.sourceName ?? "Inspected archive", value: identifier)
                        }
                    }.cardStyle()
                }
                Text("Every frozen night is included. The controller verifies the selected bytes and frozen context before publishing. Deferred work preserves this exact selection and retry key.").font(.footnote).foregroundStyle(Theme.text2)
                Button("Retain selected waveforms") { Task { await model.retainWaveforms(request, side: draft.parent.side) } }
                    .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                    .disabled(!model.canMutate || model.savedWaveformRequest == request).accessibilityIdentifier("waveforms.retain")
                BiometricBacktestPendingCard(model: model)
                if model.savedWaveformRequest == request, let result = model.receipt, request.matches(result, side: draft.parent.side) {
                    NavigationLink { BiometricDatasetDetailScreen(model: model, id: result.id) } label: { Label("Inspect waveform dataset", systemImage: "archivebox") }.accessibilityIdentifier("waveforms.inspectSaved")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Review waveforms").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("waveforms.reviewContent")
    }
}
