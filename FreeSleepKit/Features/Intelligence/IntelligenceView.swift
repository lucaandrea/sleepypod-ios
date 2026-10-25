import SwiftUI

struct IntelligenceView: View {
    @Environment(AppModel.self) private var model
    @State private var workspace = IntelligenceWorkspace.shared
    @State private var includePod = false
    @State private var consent = false
    @State private var podFacts: [SleepFact] = []
    @State private var podError: String?
    @State private var loadingPod = false
    @State private var showHistory = false
    private var evidence: [SleepFact] { workspace.facts + (includePod ? podFacts : []) }
    var body: some View {
        SleepPage(title: "Intelligence, on your terms.", subtitle: "Your own models. Your complete sleep history. A clearer picture over time.", narrow: true) {
            ModelSettingsCard(workspace: workspace)
            if let message = workspace.message {
                Text(message).sleepText(.small).accessibilityAddTraits(.updatesFrequently)
            }
            HealthHistoryCard(workspace: workspace)
            SleepCard(title: "Connect the dots", eyebrow: "PERSONAL SLEEP REPORT") {
                SleepNotesField(title: "What would you like to understand?", limit: 600, text: $workspace.question).disabled(workspace.busy)
                Toggle("Include my \(model.side.rawValue) Pod side’s 30-day summary", isOn: $includePod)
                    .toggleStyle(SleepCheckboxStyle()).disabled(workspace.busy)
                Text("Only include the Pod side you personally sleep on. Your Health history belongs to you, regardless of which Pod side is selected.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                if loadingPod { ProgressView("Loading Pod evidence…") }
                if let podError { Text(podError).foregroundStyle(SleepTheme.error) }
                DisclosureGroup("Preview information used in this request") {
                    if evidence.isEmpty { Text("Import Health history or include your connected Pod summary first.") }
                    ForEach(evidence) { Text("[\($0.id)] \($0.text)").sleepText(.small).padding(.vertical, 3) }
                }
                if workspace.provider.leavesDevice {
                    Toggle("Send this evidence and my question to \(workspace.provider == .ollama ? workspace.localAddress : workspace.provider.title) for this report.", isOn: $consent)
                        .toggleStyle(SleepCheckboxStyle()).disabled(workspace.busy)
                    Text("Raw Health samples and API keys are not included in the report prompt. The receiving provider’s data policy applies.")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                }
                Button(workspace.busy ? "Working…" : "Create my report", action: generate)
                    .buttonStyle(SleepButtonStyle(kind: .primary, fill: true))
                    .disabled(workspace.busy || !workspace.ready || evidence.isEmpty || loadingPod || (includePod && podFacts.isEmpty)
                              || (workspace.provider.leavesDevice && !consent) || AppMode.isDemo)
                if workspace.reportInProgress { Button("Cancel report", action: workspace.cancel).buttonStyle(SleepButtonStyle()) }
                Text("Model suggestions are reviewed here. Overnight Autopilot runs locally on the Pod under the limits you choose.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
            if let report = workspace.archive.reports.first { PersonalReportCard(report: report) }
            if workspace.archive.reports.count > 1 {
                DisclosureGroup("Previous reports (\(workspace.archive.reports.count - 1))", isExpanded: $showHistory) {
                    ForEach(workspace.archive.reports.dropFirst()) { PersonalReportCard(report: $0) }
                }
            }
        }.task { workspace.restore() }
            .task(id: "\(includePod)|\(model.side.rawValue)|\(model.connectionRevision)|\(model.recordRevision)") { await loadPod() }
            .onChange(of: workspace.provider) { consent = false }
            .onChange(of: workspace.modelID) { consent = false }
            .onChange(of: workspace.localAddress) { consent = false }
            .onChange(of: workspace.question) { consent = false }
            .onChange(of: evidence) { consent = false }
            .navigationTitle("Personal intelligence").navigationBarTitleDisplayMode(.inline)
    }
    private func generate() { workspace.generate(facts: evidence, consent: consent); consent = false }
    private func loadPod() async {
        consent = false; podFacts = []; podError = nil
        guard includePod else { return }
        loadingPod = true; defer { loadingPod = false }
        do {
            let analytics: SleepAnalytics = try await PodClient.configured().get("analytics", query: [
                .init(name: "side", value: model.side.rawValue), .init(name: "days", value: "30")])
            try Task.checkCancellation()
            podFacts = PersonalReportPrompt.podFacts(analytics, side: model.side)
        } catch { if !Task.isCancelled { podError = "Pod summary is unavailable. Connect your Pod or turn off its inclusion to use Health history alone." } }
    }
}
