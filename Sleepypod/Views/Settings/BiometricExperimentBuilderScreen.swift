import SwiftUI

struct BiometricExperimentBuilderScreen: View {
    let model: BiometricDatasetWorkspace
    @State private var draft: BiometricExperimentDraft
    @FocusState private var focusedField: String?
    init(model: BiometricDatasetWorkspace, dataset: BiometricDataset) { self.model = model; _draft = State(initialValue: .init(dataset: dataset)) }
    var body: some View {
        @Bindable var draft = draft
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: model.side)
                Text("Choose the protocol before looking at results. Saving an experiment does not run a job or apply a profile.").font(.footnote).foregroundStyle(Theme.text2)
                if APIBackend.current.isDemo { Text("Demo · synthetic inputs and protocols; no recorded data is evaluated.").font(.footnote).foregroundStyle(Theme.text2) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Evaluation mode").font(.headline)
                    ForEach(draft.allowedModes, id: \.self) { mode in
                        Button { draft.mode = mode } label: {
                            Label(mode.title, systemImage: draft.mode == mode ? "checkmark.circle.fill" : "circle").multilineTextAlignment(.leading)
                        }.accessibilityIdentifier("experiments.mode.\(mode.rawValue)")
                    }
                    if draft.mode == .waveform {
                        Toggle("Also replay sleep stages", isOn: $draft.waveformStages).accessibilityIdentifier("experiments.waveformStages")
                    }
                    if draft.includesStages { field("Assumed calibration quality", text: $draft.quality, id: "quality", detail: "0–1. An explicit replay assumption, not a recovered sensor measurement.") }
                    if draft.mode == .comparison { Text("Stored-reading comparison does not test numerical parameter changes.").font(.footnote).foregroundStyle(Theme.text2) }
                }.cardStyle()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Point matching").font(.headline)
                    field("Tolerance · milliseconds", text: $draft.tolerance, id: "tolerance", detail: "Whole number from 0 to 300,000.")
                    field("Fixed offset · milliseconds", text: $draft.offset, id: "offset", detail: "−3,600,000 to +3,600,000. Added to Pod timestamps on the comparison timeline.")
                }.cardStyle()
                if draft.supportsUncertainty {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Estimate whole-night uncertainty", isOn: $draft.estimateUncertainty).accessibilityIdentifier("experiments.uncertainty")
                        if draft.estimateUncertainty {
                            field("Reproducible sampling seed", text: $draft.seed, id: "seed", detail: "1–64 UTF-16 units.", numeric: false)
                            field("Resamples", text: $draft.resamples, id: "resamples", detail: "200–5,000.")
                            field("Minimum paired nights", text: $draft.minimumNights, id: "minimumNights", detail: "3–60.")
                            Text("This exploratory reporting threshold is not a validated sample-size requirement. Too few or degenerate nights yield no interval.").font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }.cardStyle()
                }
                if !draft.valid { Text("Complete the required fields within their stated limits.").font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("experiments.incomplete") }
                if let request = try? draft.request() {
                    NavigationLink { BiometricExperimentReviewScreen(model: model, parent: draft.dataset, request: request) } label: { Label("Review evaluation protocol", systemImage: "checklist") }
                        .disabled(!model.canMutate).accessibilityIdentifier("experiments.review")
                }
                BiometricBacktestPendingCard(model: model)
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Evaluation protocol").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("experiments.builderContent")
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil }.accessibilityIdentifier("experiments.keyboardDone") } }
    }
    private func field(_ title: String, text: Binding<String>, id: String, detail: String, numeric: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            TextField(title, text: text).keyboardType(numeric ? .numbersAndPunctuation : .default).textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField, equals: id).accessibilityIdentifier("experiments.\(id)")
            Text(detail).font(.footnote).foregroundStyle(Theme.text2)
        }
    }
}

struct BiometricExperimentReviewScreen: View {
    let model: BiometricDatasetWorkspace
    let parent: BiometricDataset
    // A review owns one key even if the parent editor recomputes its body.
    @State private var request: BiometricExperimentRequest
    init(model: BiometricDatasetWorkspace, parent: BiometricDataset, request: BiometricExperimentRequest) {
        self.model = model; self.parent = parent; _request = State(initialValue: request)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: parent.side)
                if APIBackend.current.isDemo { Text("Demo · saved in memory; no real evaluation.").font(.footnote).foregroundStyle(Theme.text2) }
                BiometricExperimentProtocolView(evaluationProtocol: request.protocol)
                VStack(alignment: .leading, spacing: 10) {
                    Text(parent.subjectId).font(.headline)
                    BiometricProfileIdentity(title: "Dataset", value: parent.id)
                    BiometricProfileIdentity(title: "Reviewed input hash", value: parent.contentHash)
                    Text("The controller must still retain these inputs. Saving fixes this protocol; it does not start an evaluation or change a profile.").font(.footnote).foregroundStyle(Theme.text2)
                }.cardStyle()
                Button("Save evaluation protocol") { Task { await model.createExperiment(request, parent: parent) } }
                    .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                    .disabled(!model.canMutate || model.savedExperimentRequest == request).accessibilityIdentifier("experiments.save")
                BiometricBacktestPendingCard(model: model)
                if let saved = model.savedExperiment, model.savedExperimentRequest == request {
                    NavigationLink { BiometricExperimentDetailScreen(model: model, id: saved.id) } label: { Label("Inspect saved experiment", systemImage: "flask") }.accessibilityIdentifier("experiments.inspectSaved")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Review protocol").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("experiments.reviewContent")
    }
}
