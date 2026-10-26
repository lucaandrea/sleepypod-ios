import SwiftUI
import UniformTypeIdentifiers

struct RemoteStageModelsScreen: View {
    @Environment(SettingsManager.self) private var settings
    @State private var model: RemoteStageModelWorkspace
    @State private var showFiles = false
    @State private var confirmUpload = false
    @State private var confirmApply = false
    @State private var pendingSide: Side?
    init(side: Side) {
        _model = State(
            initialValue: RemoteStageModelWorkspace(
                side: side,
                client: APIBackend.current.isDemo ? DemoRemoteStageModelClient() : CoreRemoteStageModelClient()))
    }
    private var isDemo: Bool { APIBackend.current.isDemo }
    private var calendar: Calendar { SleepCalendar.calendar(timeZone: settings.timeZone) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker(
                    "Model side",
                    selection: Binding(
                        get: { model.side },
                        set: {
                            if model.prepared != nil {
                                pendingSide = $0
                            } else {
                                let side = $0
                                Task { await model.load(side: side) }
                            }
                        })
                ) { ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) } }.pickerStyle(.segmented)
                    .disabled(model.busy)
                Text(
                    "Models are stored per sleeper on the Pod. Importing a model adds it to the library; activation is a separate choice."
                ).font(.footnote).foregroundStyle(Theme.text2)
                if isDemo {
                    Text("Demo · model scores are simulated. Selection changes stay in memory.").font(.footnote)
                        .foregroundStyle(Theme.amber)
                }
                if model.busy { ProgressView("Updating model library…") }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(Theme.amber).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let notice = model.notice {
                    Text(notice).font(.footnote).foregroundStyle(Theme.text2).fixedSize(
                        horizontal: false, vertical: true)
                }
                Button("Reload library", systemImage: "arrow.clockwise") { Task { await model.load() } }.disabled(
                    model.busy)
                if let state = model.state {
                    if state.supported {
                        library(state)
                        importCard
                        if let prepared = model.prepared { review(prepared) }
                        if state.previewSupported && (model.prepared != nil || model.chosen != nil) {
                            previewCard
                        }
                    } else {
                        Text(
                            "This controller does not expose the model-library API yet. Update the controller to use remote model imports and selection. Your existing iPhone stage models remain available in Sleep."
                        )
                        .font(.subheadline).foregroundStyle(Theme.text2).cardStyle()
                    }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Pod stage models").navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): Task { await model.prepare(url) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .confirmationDialog(
                "Save this model to \(settings.sideName(for: model.side))’s library?", isPresented: $confirmUpload,
                titleVisibility: .visible
            ) {
                Button("Upload model") { Task { await model.upload() } }
            } message: {
                Text(
                    "The model document and its training metadata will be sent to your connected Pod. This does not activate it or replace the current model."
                )
            }
            .confirmationDialog(
                model.choice == nil ? "Use rules for this side?" : "Use this model for this side?",
                isPresented: $confirmApply, titleVisibility: .visible
            ) {
                Button(model.choice == nil ? "Use rules only" : "Use this model") { Task { await model.apply() } }
            } message: {
                Text(
                    "This changes how the Pod stages this sleeper’s nights. Rules remain the fallback when a model cannot stage a night. The iPhone’s local stage-model selection and existing Health entries are managed separately."
                )
            }
            .confirmationDialog(
                "Discard the prepared model and change sides?",
                isPresented: Binding(get: { pendingSide != nil }, set: { if !$0 { pendingSide = nil } }),
                titleVisibility: .visible
            ) {
                if let side = pendingSide {
                    Button("Discard and switch", role: .destructive) {
                        pendingSide = nil
                        Task { await model.load(side: side) }
                    }
                }
            }
    }
    private func library(_ state: RemoteStageModelState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Staging model").font(.headline)
            if let selected = state.selection?.model {
                Text("\(state.selection?.active == true ? "Active" : "Stored, inactive"): \(selected.version)").font(
                    .subheadline
                ).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Rules are active. No model is selected.").foregroundStyle(Theme.text2)
            }
            if state.library.isEmpty {
                Text("No models in this side’s library.").font(.footnote).foregroundStyle(Theme.text3)
            }
            ForEach(state.library) { item in
                Button {
                    model.choice = item.id
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.choice == item.id ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.version).foregroundStyle(Theme.text1).fixedSize(horizontal: false, vertical: true)
                            Text(
                                "\(item.kind == "forest" ? "Random forest" : "Logistic regression")\(item.active ? " · Active" : "")"
                            ).font(.caption).foregroundStyle(Theme.text2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("stageModel.choice.\(item.id)")
            }
            Button {
                model.choice = nil
            } label: {
                Label(
                    "Rules only\(state.selection?.active == false ? " · Active" : "")",
                    systemImage: model.choice == nil ? "largecircle.fill.circle" : "circle")
            }.accessibilityIdentifier("stageModel.rulesOnly")
            if let selected = model.chosen {
                DisclosureGroup("Chosen model identity") {
                    BiometricProfileIdentity(title: "Controller model hash", value: selected.modelHash ?? "Not reported")
                }.accessibilityIdentifier("stageModel.identity")
                StageModelScorecard(metrics: selected.metrics)
            }
            Button(model.choice == nil ? "Use rules only" : "Use this model") { confirmApply = true }.disabled(
                !model.canApply
            ).accessibilityIdentifier("stageModel.apply")
        }.cardStyle().disabled(model.busy)
    }
    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a model").font(.headline)
            Text(
                "Choose a model JSON file of at most 4 MiB. The document’s feature contract and test vectors are checked on this iPhone and again by the controller."
            ).font(.footnote).foregroundStyle(Theme.text2)
            Button("Choose model JSON", systemImage: "doc.badge.plus") { showFiles = true }.disabled(
                model.busy).accessibilityIdentifier("stageModel.chooseFile")
            if isDemo {
                Text("You can inspect a file locally in Demo. Uploading and comparing that file require a connected Pod.").font(.footnote)
                    .foregroundStyle(Theme.text3)
            }
        }.cardStyle()
    }
    private func review(_ document: RemoteStageModelDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review import").font(.headline)
            Text(document.version).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text(model.filename ?? "Model JSON").font(.caption).foregroundStyle(Theme.text2)
            StageModelScorecard(metrics: document.metrics)
            Button("Save to library") { confirmUpload = true }.disabled(model.busy || isDemo)
            Button("Discard file", role: .destructive) { model.discardFile() }.disabled(model.busy)
        }.cardStyle()
    }
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preview \(model.previewTitle)").font(
                .headline
            ).fixedSize(horizontal: false, vertical: true)
            Picker("Model preview nights", selection: $model.nights) {
                Text("Last night").tag(1)
                Text("7 nights").tag(7)
                Text("30 nights").tag(30)
            }.pickerStyle(.menu)
            Button("Compare with rules") { Task { await model.previewModel() } }.disabled(
                !model.canPreview || (isDemo && model.prepared != nil)).accessibilityIdentifier("stageModel.preview")
            if model.previewing { ProgressView("Scoring recent nights…") }
            if let preview = model.preview {
                Text("\(preview.nights.count) nights scored").font(.subheadline)
                if preview.pooled == nil {
                    Text("No overlapping imported Watch stages to score. This does not establish model accuracy.").font(
                        .footnote
                    ).foregroundStyle(Theme.text2)
                }
                agreement("Model", preview.pooled)
                agreement("Rules", preview.rulesPooled)
                ForEach(preview.nights) { night in
                    DisclosureGroup(
                        Date(timeIntervalSince1970: night.enteredBedAt / 1000).formatted(
                            Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone))
                    ) {
                        agreement("Model", night.agreement)
                        agreement("Rules", night.rulesAgreement)
                    }
                }
            }
        }.cardStyle()
    }
    @ViewBuilder private func agreement(_ title: String, _ value: RemoteStageModelPreview.Agreement?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title): \(Int(value.accuracy * 100))% agreement · \(value.epochs) epochs").font(.subheadline)
                if let kappa = value.kappa {
                    Text("κ \(kappa.formatted(.number.precision(.fractionLength(2))))").font(.footnote).foregroundStyle(
                        Theme.text2)
                }
            }
        }
    }
}

private struct StageModelScorecard: View {
    let metrics: StageModelJSON?
    private var score: RemoteStageModelScore { .init(metrics: metrics) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported held-out agreement with Watch").font(.subheadline.bold())
            Text(score.kappa.map { "κ " + $0.formatted(.number.precision(.fractionLength(2))) } ?? "Not evaluated")
                .font(.title2.monospacedDigit())
            if let nights = score.nights {
                Text("\(nights) held-out nights").font(.footnote).foregroundStyle(Theme.text2)
            }
            if let baseline = score.baseline, let kappa = score.kappa {
                Text(
                    "\((kappa - baseline).formatted(.number.sign(strategy: .always()).precision(.fractionLength(2)))) over rules (κ \(baseline.formatted(.number.precision(.fractionLength(2)))))"
                ).font(.footnote)
            } else {
                Text("No rules comparison is included.").font(.footnote).foregroundStyle(Theme.text2)
            }
            ForEach(RemoteSleepStage.allCases) { stage in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(stage.title) · \(score.recall[stage].map { Int($0 * 100).description + "%" } ?? "—")").font(
                        .footnote)
                    if let recall = score.recall[stage] {
                        ProgressView(value: recall).tint(
                            stage == .wake
                                ? Theme.amber : stage == .deep ? .indigo : stage == .rem ? .purple : Theme.cool)
                    }
                }
            }
            Text(
                "κ measures agreement beyond chance: 0 is chance-level and 1 is perfect agreement. These are uploader-provided scores, not independently verified agreement, clinical accuracy or a guarantee for future nights. Missing scores remain blank."
            ).font(.caption).foregroundStyle(Theme.text3)
        }
    }
}
