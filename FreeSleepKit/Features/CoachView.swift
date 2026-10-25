import SwiftUI

struct CoachView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("podURL") private var address = ""
    var body: some View {
        NavigationStack {
        CoachForm(side: model.side, demo: model.demo).id("\(address)|\(model.settings?.id ?? "")|\(model.side.rawValue)|\(model.recordRevision)")
        }
    }
}
private struct CoachForm: View {
    @Environment(AppModel.self) private var model
    let side: BedSide
    let demo: Bool
    @State private var providers: [CoachProvider] = []
    @State private var providersError: String?
    @State private var checkingProviders = false
    @State private var provider = "rules"
    @State private var days = 30
    @State private var share = false
    @State private var question = "What patterns stand out in my recent nights?"
    @State private var session = CoachSession()
    @State private var request: Task<Void, Never>?
    @State private var usageRevision = 0
    private var configured: Bool { provider == "rules" || providers.contains { $0.provider == provider && $0.configured } }
    var body: some View {
        SleepPage(title: "A little perspective.", subtitle: "Thoughtful insights, grounded in your own routine.", narrow: true) {
            SidePicker()
            SleepCard(title: "Your models. Your whole history.", eyebrow: "PERSONAL INTELLIGENCE") {
                Text("Add your OpenAI or Gemini key, use Apple’s on-device model, and explore your complete Apple Health sleep history.").foregroundStyle(SleepTheme.secondary)
                NavigationLink("Open personal intelligence") { IntelligenceView() }.buttonStyle(SleepButtonStyle(kind: .primary))
            }
            SleepCard(title: "What would you like to explore?", eyebrow: "YOUR SLEEP COACH") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("History range").sleepText(.small).foregroundStyle(SleepTheme.secondary)
                    SleepSegmentedPicker(title: "History range", options: [7, 30, 90], selection: $days) { "\($0) days" }
                }.disabled(session.busy)
                SleepFormField(title: "Insight source") {
                    Picker("Insight source", selection: $provider) {
                        Text("Local calculations · no model or sharing").tag("rules")
                        ForEach(providers.filter { $0.provider != "rules" }) { option in
                            Text(option.model + (option.configured ? "" : " · set up on server")).tag(option.provider).disabled(!option.configured)
                        }
                    }.pickerStyle(.menu).labelsHidden().tint(SleepTheme.text).accessibilityLabel("Insight source")
                }.disabled(session.busy)
                if checkingProviders { Text("Checking model availability…").sleepText(.caption) }
                if let providersError {
                    Text(providersError).sleepText(.small).foregroundStyle(SleepTheme.error)
                    Button("Retry") { Task { await loadProviders() } }.buttonStyle(SleepButtonStyle())
                }
                if provider == "rules" {
                    Text("Local calculations summarize this range. Choose a model to ask a question.").sleepText(.small).foregroundStyle(SleepTheme.secondary)
                } else {
                    SleepNotesField(title: "Your question", limit: 1000, text: $question).disabled(session.busy)
                    Toggle("Share my numerical sleep summary and this question with the selected model for this request.", isOn: $share)
                        .toggleStyle(SleepCheckboxStyle()).disabled(session.busy)
                }
                Button(session.busy ? "Finding perspective…" : "Explore my nights") { generate() }
                    .buttonStyle(SleepButtonStyle(kind: .primary, fill: true))
                    .disabled(session.busy || !configured || (provider != "rules" && (!share || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
                Text("Suggestions support your routine. They do not diagnose conditions or change your bed.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
            if let error = session.error { Text(error).foregroundStyle(SleepTheme.error) }
            if let result = session.result {
                SleepCard(title: result.headline, eyebrow: result.model) {
                    Text("\(side.rawValue.capitalized) side · \(days) days").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    if result.grounding?.version == 1 { Text("Calculated observations").sleepText(.cardTitle) }
                    ForEach(Array(result.observations.enumerated()), id: \.offset) { _, text in Text(text).sleepText(.body) }
                    CoachEvidenceView(grounding: result.grounding)
                    Text("Try one small change").sleepText(.cardTitle)
                    if let grounding = result.grounding {
                        Text(grounding.suggestions == "rules" ? "Local suggestions" : "Model suggestions · review before making changes")
                            .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    }
                    ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, text in Text(text).sleepText(.body) }
                    ForEach(Array(result.limitations.enumerated()), id: \.offset) { _, text in Text(text).sleepText(.caption).foregroundStyle(SleepTheme.secondary) }
                }
            }
            CoachUsageView(revision: usageRevision)
        }.onChange(of: provider) { reset() }.onChange(of: days) { reset() }.onChange(of: question) { reset() }
            .task { await loadProviders() }.onDisappear { request?.cancel(); session.invalidate() }
    }
    private func reset() { request?.cancel(); session.invalidate(); share = false }
    private func loadProviders() async {
        checkingProviders = true; providersError = nil
        defer { checkingProviders = false }
        do {
            let loaded: [CoachProvider] = demo
                ? [.init(provider: "rules", model: "Deterministic insights", configured: true),
                   .init(provider: "openai", model: "Demo model · no external calls", configured: true)]
                : try await PodClient.configured().get("ai/providers")
            guard !Task.isCancelled else { return }; providers = loaded
        } catch {
            if !Task.isCancelled { providersError = "Model availability could not be loaded. Local calculations remain available." }
        }
    }
    private func generate() {
        guard !session.busy, configured, provider == "rules" || share else { return }
        let provider = provider; let days = days; let sharing = share; let question = provider == "rules" ? "" : question
        share = false
        request = Task {
            defer { usageRevision += 1 }
            await session.run {
                if demo {
                    guard let analytics = model.demoHistory.analytics(side: side, days: days) else { throw PodError.message("The sample coaching could not be loaded.") }
                    if provider != "rules" { try model.demoCoachUsage.record() }
                    return DemoSleepSummary.coaching(analytics, provider: provider)
                }
                return try await PodClient.configured().coach(side: side, provider: provider, share: sharing, question: question, days: days)
            }
        }
    }
}
