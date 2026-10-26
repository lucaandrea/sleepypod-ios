import SwiftUI

/// Both paths retain native grouped settings; coaching adds local calculations and explicit ranges.
struct PersonalReportsScreen: View {
    let coach: Bool
    let nativeActions: NativePodActionBridge
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var workspace = IntelligenceWorkspace.shared
    @State private var pod = PersonalEvidenceWorkspace()
    @State private var includePod: Bool
    @State private var includeHealth: Bool
    @State private var local: Bool
    @State private var days = 30
    @State private var consent = false
    @State private var showLocal = false
    @State private var showHistory = false
    @State private var refresh = 0
    @State private var evidenceScope: String?
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("apiBackend") private var backend = ""
    init(coach: Bool = false, nativeActions: NativePodActionBridge) {
        self.coach = coach; self.nativeActions = nativeActions
        _includePod = State(initialValue: coach); _includeHealth = State(initialValue: !coach); _local = State(initialValue: coach)
    }
    private var title: String { coach ? "Sleep coach" : "Personal reports" }
    private var evidence: [SleepFact] { (includeHealth ? workspace.facts : []) + (includePod ? pod.facts : []) }
    private var scope: String { "\(includePod)|\(model.side.rawValue)|\(days)|\(model.connectionRevision)|\(model.recordRevision)|\(ownerRevision)|\(address)|\(backend)|\(refresh)" }
    private var canUseEvidence: Bool {
        !pod.loading && !evidence.isEmpty && (!includePod || (evidenceScope == scope && pod.error == nil && pod.hasObservations))
    }
    var body: some View {
        FeaturePage(title: title) {
            if coach { SidePicker() }
            if coach {
                FeatureSection(title: "Explore your routine") {
                    FeatureSegments(title: "History range", options: [7, 30, 90], selection: $days) { "\($0) days" }
                        .accessibilityIdentifier("reports.range")
                    FeatureSegments(title: "Insight source", options: [true, false], selection: $local) {
                        $0 ? (dynamicTypeSize.isAccessibilitySize ? "Local" : "Local calculations")
                            : (dynamicTypeSize.isAccessibilitySize ? "Model" : "Chosen model")
                    }
                        .accessibilityIdentifier("reports.source")
                    Text(local ? "Calculated observations stay on this device. No model or sharing is involved."
                         : "Choose a model, review the evidence, then create a report. Suggestions never change the bed.")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                }
            }
            if !local { connections }
            FeatureSection(title: local ? "Evidence" : "Create a report") {
                if !local { FeatureNotes(title: "What would you like to understand?", limit: 600, text: $workspace.question).disabled(workspace.busy) }
                Toggle("Include my \(model.side.rawValue) Pod side’s \(days)-day summary", isOn: $includePod)
                    .accessibilityIdentifier("reports.includePod").tint(Theme.green).disabled(workspace.busy)
                Toggle("Include my imported Health history", isOn: $includeHealth)
                    .accessibilityIdentifier("reports.includeHealth").tint(Theme.green).disabled(workspace.busy)
                Text("Only include the Pod side you personally sleep on. Health history belongs to you and keeps its own dated range; the Pod range does not filter that import.")
                    .font(.caption).foregroundStyle(Theme.text2)
                if includePod {
                    if pod.example { FeatureStatus(title: "EXAMPLE · NOT YOUR BED", tone: .warning) }
                    if pod.loading { ProgressView("Loading Pod evidence…") }
                    if let error = pod.error { Text(error).foregroundStyle(Theme.red) }
                    if !pod.loading && pod.error == nil && !pod.hasObservations {
                        Text("No eligible observations in this range. Missing records do not establish zero sleep.").font(.subheadline)
                    }
                    Button("Refresh Pod summary") { reset(); refresh += 1 }.buttonStyle(GlassButtonStyle()).disabled(workspace.busy || pod.loading)
                }
                DisclosureGroup("Preview information used in this request") {
                    if evidence.isEmpty { Text("Import Health history or include your connected Pod summary first.") }
                    ForEach(evidence) { Text("[\($0.id)] \($0.text)").font(.subheadline).padding(.vertical, 3) }
                }.accessibilityIdentifier("reports.evidence")
                if local {
                    Button("Explore this range") { showLocal = true }.buttonStyle(PrimaryButtonStyle())
                        .disabled(!canUseEvidence).accessibilityIdentifier("reports.explore")
                } else { modelRequest }
            }
            if showLocal && local {
                FeatureSection(title: "Calculated observations", badge: pod.example ? "EXAMPLE DATA" : nil) {
                    ForEach(evidence) { Text("[\($0.id)] \($0.text)").font(.body).accessibilityIdentifier("reports.localFact.\($0.id)") }
                    Text("These are descriptive calculations. They do not diagnose conditions, establish causes or change the bed.")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
            }
            if !local {
                if let message = workspace.message { Text(message).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
                if let report = workspace.archive.reports.first { PersonalReportCard(report: report) }
                if workspace.archive.reports.count > 1 {
                    DisclosureGroup("Previous reports (\(workspace.archive.reports.count - 1))", isExpanded: $showHistory) {
                        ForEach(workspace.archive.reports.dropFirst()) { PersonalReportCard(report: $0) }
                    }
                }
            }
        }.frame(maxWidth: 720).frame(maxWidth: .infinity)
            .task { workspace.restore() }
            .task(id: scope) { reset(); await loadPod() }
            .onChange(of: workspace.provider) { reset() }
            .onChange(of: workspace.modelID) { reset() }
            .onChange(of: workspace.localAddress) { reset() }
            .onChange(of: workspace.question) { reset() }
            .onChange(of: evidence) { reset() }
            .onChange(of: local) { reset() }
            .onDisappear { workspace.cancel(); pod.invalidate(); consent = false }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private var connections: some View {
        GroupedCard {
            NavigationLink { ModelConnectionScreen() } label: {
                SettingsRow("Model", icon: "sparkles", chevron: true) { RowValue(workspace.provider.title) }
            }
            NavigationLink { ImportedHealthScreen() } label: { SettingsRow("Health history", icon: "heart", chevron: true) }
        }.buttonStyle(.plain)
    }
    private var modelRequest: some View {
        Group {
            if workspace.provider.leavesDevice {
                Toggle("Send this evidence and my question to \(workspace.provider == .ollama ? workspace.localAddress : workspace.provider.title) for this report.", isOn: $consent)
                    .accessibilityIdentifier("reports.consent").tint(Theme.green).disabled(workspace.busy)
                Text("Raw Health samples and API keys are not included in the prompt. The receiving provider’s data policy applies.")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
            Button(workspace.busy ? "Working…" : "Create my report", action: generate)
                .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("reports.generate")
                .disabled(workspace.busy || !workspace.ready || !canUseEvidence
                          || workspace.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (workspace.provider.leavesDevice && !consent) || AppMode.isDemo)
            if workspace.reportInProgress { Button("Cancel report", action: workspace.cancel).buttonStyle(GlassButtonStyle()) }
            Text(AppMode.isDemo ? "Demo never sends a report to a model." : "Review model suggestions here. No report changes your bed or enables overnight adjustments.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private func reset() { consent = false; showLocal = false; workspace.cancel() }
    private func generate() {
        let requestedScope = scope, requestedEvidence = evidence
        let source = [includeHealth ? workspace.source?.name : nil, includePod ? "Pod \(model.side.rawValue) · \(days) days" : nil].compactMap { $0 }.joined(separator: " + ")
        workspace.generate(facts: requestedEvidence, consent: consent, sourceName: source,
                           valid: { scope == requestedScope && evidence == requestedEvidence }); consent = false
    }
    private func loadPod() async {
        pod.invalidate(); evidenceScope = nil
        guard includePod else { return }
        let side = model.side.rawValue, range = days, requestedScope = scope
        if AppMode.isDemo {
            #if DEBUG
            let empty = UserDefaults.standard.string(forKey: "uiReportScenario") == "empty"
            #else
            let empty = false
            #endif
            pod.showExample(side: side, days: range, empty: empty); evidenceScope = requestedScope; return
        }
        await pod.load(side: side, days: range) {
            if AppMode.isCore { return try await nativeActions.evidence(side: side, days: range) }
            let analytics: SleepAnalytics = try await PodClient.configured().get("analytics", query: [
                .init(name: "side", value: side), .init(name: "days", value: "\(range)")])
            let facts = PersonalReportPrompt.podFacts(analytics, side: BedSide(rawValue: side) ?? .left)
            let end = Date.now
            return .init(side: side, days: range, timeZone: analytics.timeZone, start: end.addingTimeInterval(-Double(range) * 86400), end: end,
                         facts: facts.map { .init(id: $0.id, text: $0.text) }, summary: "Recorded Pod presence, not measured sleep.",
                         hasObservations: analytics.summary.recordedNights > 0)
        }
        if !Task.isCancelled && requestedScope == scope { evidenceScope = requestedScope }
    }
}
