import SwiftUI

struct PersonalReportsScreen: View {
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
        FeaturePage(title: "Personal reports") {
            GroupedCard {
                NavigationLink { ModelConnectionScreen() } label: {
                    SettingsRow("Model", icon: "sparkles", chevron: true) { RowValue(workspace.provider.title) }
                }
                NavigationLink { ImportedHealthScreen() } label: {
                    SettingsRow("Health history", icon: "heart", chevron: true)
                }
            }.buttonStyle(.plain)
            if let message = workspace.message {
                Text(message).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
            }
            FeatureSection(title: "Create a report", eyebrow: "PERSONAL SLEEP REPORT") {
                FeatureNotes(title: "What would you like to understand?", limit: 600, text: $workspace.question).disabled(workspace.busy)
                Toggle("Include my \(model.side.rawValue) Pod side’s 30-day summary", isOn: $includePod)
                    .tint(Theme.green).disabled(workspace.busy)
                Text("Only include the Pod side you personally sleep on. Your Health history belongs to you, regardless of which Pod side is selected.")
                    .font(.caption).foregroundStyle(Theme.text2)
                if loadingPod { ProgressView("Loading Pod evidence…") }
                if let podError { Text(podError).foregroundStyle(Theme.red) }
                DisclosureGroup("Preview information used in this request") {
                    if evidence.isEmpty { Text("Import Health history or include your connected Pod summary first.") }
                    ForEach(evidence) { Text("[\($0.id)] \($0.text)").font(.subheadline).padding(.vertical, 3) }
                }
                if workspace.provider.leavesDevice {
                    Toggle("Send this evidence and my question to \(workspace.provider == .ollama ? workspace.localAddress : workspace.provider.title) for this report.", isOn: $consent)
                        .tint(Theme.green).disabled(workspace.busy)
                    Text("Raw Health samples and API keys are not included in the report prompt. The receiving provider’s data policy applies.")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                Button(workspace.busy ? "Working…" : "Create my report", action: generate)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(workspace.busy || !workspace.ready || evidence.isEmpty || loadingPod || (includePod && podFacts.isEmpty)
                              || (workspace.provider.leavesDevice && !consent) || AppMode.isDemo)
                if workspace.reportInProgress { Button("Cancel report", action: workspace.cancel).buttonStyle(GlassButtonStyle()) }
                Text("Model suggestions are reviewed here. Overnight Autopilot runs locally on the Pod under the limits you choose.")
                    .font(.caption).foregroundStyle(Theme.text2)
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
            .navigationTitle("Personal reports").navigationBarTitleDisplayMode(.inline)
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
