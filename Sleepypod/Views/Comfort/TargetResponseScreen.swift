import SwiftUI
import FreeSleepKit

struct TargetResponseScreen: View {
    let side: Side
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var phase
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("household.boundaryRevision") private var boundary = ""
    @State private var workspace = TargetResponseWorkspace()
    @State private var predictive = PredictiveTargetWorkspace()
    private var scope: String { "\(owner)|\(backend)|\(endpoint)|\(host)|\(boundary)|\(side)|\(phase)" }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                // An async reply can arrive after the last timeline tick. Validate at render time.
                let now = Date()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Can small changes be predicted?").font(.title2.bold())
                    Text("Learn from recorded 1°F target changes on the \(settings.sideName(for: side)) physical zone. This research estimates water response, not body temperature or better sleep.")
                        .foregroundStyle(Theme.text2)
                    if APIBackend.current.isDemo {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "flask").foregroundStyle(Theme.amber).accessibilityHidden(true)
                            Text("Practice · artificial response observations").foregroundStyle(Theme.text1)
                        }.font(.footnote)
                    }
                    if PersonalWorkspaceBoundary.isActive {
                        Text("These owner research records are unavailable in a personal workspace. Your private account does not inherit another sleeper's history.")
                    } else {
                        Button {
                            Task { await workspace.refresh() }
                        } label: {
                            Label(workspace.operation == .reading ? "Reading recorded changes…" : "Check recorded changes", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }.buttonStyle(.bordered).disabled(workspace.operation != nil)
                            .accessibilityIdentifier("response.refresh")
                        if workspace.operation == .reading { ProgressView("Reading Pod evidence…") }
                        if let status = workspace.status(at: now) {
                            evidence(status)
                            TargetResponseEvaluationView(status: status, preview: workspace.preview(at: now), workspace: workspace)
                        } else if workspace.operation == .fitting {
                            ProgressView("Evaluating later nights…").accessibilityIdentifier("response.fitting")
                        } else if workspace.operation != .reading, workspace.error == nil {
                            Text("Check the Pod for current evidence. Readings expire; missing data never counts as a successful evaluation.")
                                .foregroundStyle(Theme.text2).accessibilityIdentifier("response.waiting")
                        }
                        if let error = workspace.error {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.amber).accessibilityHidden(true)
                                Text(error).foregroundStyle(Theme.text1).accessibilityIdentifier("response.error")
                            }
                        }
                        if let notice = workspace.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                        Divider()
                        PredictiveTargetSection(workspace: predictive)
                    }
                    Divider()
                    Text("Reading evidence and evaluating predictions leave your bed settings unchanged. Model fitting stays on your Pod; cloud AI is not used.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: 780, alignment: .leading)
                    .padding(20).padding(.bottom, 80).frame(maxWidth: .infinity)
            }
        }.background(Theme.background).navigationTitle("Temperature response").navigationBarTitleDisplayMode(.inline)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .task(id: scope) {
                workspace.invalidate()
                predictive.invalidate()
                guard phase == .active, !PersonalWorkspaceBoundary.isActive else { return }
                let client: (any TargetResponseClient)?
                if APIBackend.current.isDemo {
                    var mode = "ready"
                    #if DEBUG
                    mode = UserDefaults.standard.string(forKey: "uiTargetResponseMode") ?? "ready"
                    #endif
                    client = TargetResponseExample(mode: mode)
                    predictive.configure(client: PredictiveTargetExample(unavailable: mode == "unavailable"), side: side)
                } else if APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() {
                    client = CoreTargetResponseClient(transport: transport)
                    predictive.configure(client: CorePredictiveTargetClient(transport: transport), side: side)
                } else { client = nil }
                workspace.configure(client: client, side: side)
            }
            .onDisappear { workspace.invalidate(); predictive.invalidate() }
    }

    private func evidence(_ status: TargetResponseResearch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status.state).font(.headline).accessibilityIdentifier("response.state")
            Text("\(status.completeNights) of \(status.evidence.reviewedNights) reviewed nights contain qualifying changes. At least 20 distinct nights are needed to evaluate a fit.")
                .foregroundStyle(Theme.text2).accessibilityIdentifier("response.counts")
            Text("\(status.evidence.coolingWindows) cooling · \(status.evidence.warmingWindows) warming observations")
                .font(.subheadline).monospacedDigit()
            Text(status.reason).font(.subheadline).foregroundStyle(Theme.text2)
            if !status.evidence.exclusions.isEmpty {
                ResponseDisclosure(title: "Why observations were excluded", identifier: "response.exclusions") {
                    ForEach(Array(status.evidence.exclusions.enumerated()), id: \.offset) { _, item in
                        Text("\(item.date) · \(item.count): \(item.reason)").font(.footnote).padding(.vertical, 6)
                    }
                    if status.evidence.exclusionsTruncated { Text("More exclusions are retained on the Pod.").font(.footnote) }
                }
            }
        }
    }
}

private struct TargetResponseEvaluationView: View {
    let status: TargetResponseResearch
    let preview: TargetResponsePreview?
    let workspace: TargetResponseWorkspace
    @Environment(SettingsManager.self) private var settings
    private var celsius: Bool { settings.temperatureFormat == .celsius }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if status.canEvaluate {
                Button { Task { await workspace.evaluate() } } label: {
                    Text("Evaluate response model").frame(minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background).disabled(workspace.operation != nil)
                    .accessibilityIdentifier("response.fit")
            }
            if let model = status.model {
                ResponseDisclosure(title: "How the model was checked", identifier: "response.comparison") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(model.trainingDates.count) earlier nights fit the model. \(model.calibrationDates.count) separate nights set error ranges. \(model.validationDates.count) later nights test predictions.")
                            .foregroundStyle(Theme.text2)
                        ForEach(model.horizons) { horizon in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(horizon.minutes) minutes · \(horizon.validation.passes ? "Passed comparison" : "Needs improvement")").font(.headline)
                                metric("Average prediction error", TargetResponseTemperature.text(horizon.validation.modelMaeF, celsius: celsius, difference: true))
                                metric("Best simple alternative", TargetResponseTemperature.text(horizon.validation.bestBaselineF, celsius: celsius, difference: true))
                                metric("Inside the error range", horizon.validation.intervalCoverage.formatted(.percent.precision(.fractionLength(0))))
                                metric("Comparable test conditions", horizon.validation.supportedFraction.formatted(.percent.precision(.fractionLength(0))))
                            }
                        }
                        Text("Lower error is better. Comparisons include holding the last reading, following the recent trend and a simple target response. Passing does not prove that changing the target improves comfort.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }
            if status.canPreview {
                Divider()
                Text("Preview nearby targets with current readings. No target is selected or sent to your bed.").foregroundStyle(Theme.text2)
                Button {
                    Task { await workspace.readPreview() }
                } label: {
                    Text(workspace.operation == .previewing ? "Reading current conditions…" : preview == nil ? "Preview nearby targets" : "Refresh response preview")
                        .frame(minHeight: 44)
                }.buttonStyle(.bordered).disabled(workspace.operation != nil).accessibilityIdentifier("response.preview")
                if let preview {
                    Text(preview.reason).font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("response.previewReason")
                    ForEach(preview.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            Divider()
                            Text("If the target were \(TargetResponseTemperature.text(candidate.targetF, celsius: celsius))")
                                .font(.headline).accessibilityIdentifier("response.target.\(Int(candidate.targetF))")
                            if candidate.predictions.isEmpty { Text(candidate.reason).foregroundStyle(Theme.text2) }
                            ForEach(candidate.predictions) { prediction in
                                Text("\(prediction.minutes) minutes: \(TargetResponseTemperature.text(prediction.waterF, celsius: celsius)) estimated water")
                                    .monospacedDigit()
                                Text("\(TargetResponseTemperature.text(prediction.lowerF, celsius: celsius))–\(TargetResponseTemperature.text(prediction.upperF, celsius: celsius)) observed error range")
                                    .foregroundStyle(Theme.text2).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(Theme.text2); Spacer(minLength: 18); Text(value).monospacedDigit() }
            VStack(alignment: .leading, spacing: 4) { Text(label).foregroundStyle(Theme.text2); Text(value).monospacedDigit() }
        }.font(.subheadline).accessibilityElement(children: .combine)
    }
}

/// Make the full disclosure label actionable on supported iOS versions, including VoiceOver.
private struct ResponseDisclosure<Content: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small).accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed").accessibilityIdentifier(identifier)
            if expanded { content() }
        }
    }
}
