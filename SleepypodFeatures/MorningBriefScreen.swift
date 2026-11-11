import SwiftUI

struct MorningBriefScreen: View {
    let report: PersonalSleepReport
    var example = false
    @State private var workspace = IntelligenceWorkspace.shared
    @State private var question = ""
    @State private var consent = false
    @AppStorage(PersonalWorkspaceBoundary.preferenceKey) private var personalAccount = false
    @Environment(\.scenePhase) private var phase
    private var currentReport: PersonalSleepReport {
        workspace.archive.reports.first { $0.id == report.id && $0.facts == report.facts } ?? report
    }
    private var canAsk: Bool {
        !example && !AppMode.isDemo && !personalAccount && phase == .active && !workspace.busy && workspace.ready
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !report.facts.isEmpty
            && (!workspace.provider.leavesDevice || consent) && (currentReport.followUps?.count ?? 0) < 10
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if personalAccount || phase != .active {
                    ContentUnavailableView("Your report is private", systemImage: "lock")
                } else {
                    if example { Label("Example · no personal data", systemImage: "info.circle").font(.subheadline).foregroundStyle(Theme.reportAccent) }
                    MorningBriefContent(report: report)
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("An experiment from this report").font(.title3.bold()).accessibilityIdentifier("brief.experiment")
                        if let experiment = ReportDocument(text: report.text, facts: report.facts).experiment {
                            Text("AI suggestion · not started").font(.caption.weight(.semibold)).foregroundStyle(Theme.reportAccent)
                            ReportDocumentView(document: experiment, facts: report.facts)
                            Text("Review this saved suggestion before trying it. No alarm, temperature or automation is changed here.")
                                .font(.caption).foregroundStyle(Theme.text2)
                        } else {
                            Text("No separate experiment is available here. Read the full interpretation or ask below for one small idea and how to evaluate it.")
                                .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("brief.experiment.unavailable")
                        }
                    }
                    DisclosureGroup { PersonalReportCard(report: report) } label: {
                        Text("Full interpretation and evidence")
                    }
                    Divider()
                    followUp
                }
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .center)
        }.scrollDismissesKeyboard(.interactively)
            .background(Theme.background).navigationTitle("Morning brief").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("brief.scroll")
            .task { if !example && !AppMode.isDemo && !personalAccount { workspace.restore() } }
            .onChange(of: workspace.provider) { reset() }
            .onChange(of: workspace.modelID) { reset() }
            .onChange(of: workspace.localAddress) { reset() }
            .onChange(of: question) { reset() }
            .onChange(of: personalAccount) { reset() }
            .onChange(of: phase) { if phase != .active { reset() } }
            .onDisappear { reset() }
    }
    private var followUp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about this report").font(.title3.bold())
            Text("Answers use the calculated facts saved with this report. They cannot see new nights, diagnose a condition or control the bed.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if !example {
                NavigationLink { ModelConnectionScreen() } label: {
                    Label(workspace.provider.title, systemImage: "sparkles").font(.subheadline)
                }.accessibilityIdentifier("brief.model")
            }
            FeatureNotes(title: "Your question", limit: 600, text: $question).disabled(workspace.busy)
                .accessibilityIdentifier("brief.question")
            if workspace.provider.leavesDevice {
                Toggle("Send this report’s calculated facts and my question to \(workspace.provider == .ollama ? workspace.localAddress : workspace.provider.title) for this answer.", isOn: $consent)
                    .font(.subheadline).disabled(workspace.busy || example).accessibilityIdentifier("brief.consent")
            }
            Button(workspace.busy ? "Creating answer…" : "Ask about saved evidence", action: ask)
                .buttonStyle(PrimaryButtonStyle()).disabled(!canAsk).accessibilityIdentifier("brief.ask")
            if workspace.reportInProgress { Button("Cancel answer") { workspace.cancel() }.buttonStyle(GlassButtonStyle()) }
            if example { Text("Practice does not read Health or send a model request.").font(.caption).foregroundStyle(Theme.text2) }
            else if !workspace.ready { Text("Choose an available model above before asking a question.").font(.caption).foregroundStyle(Theme.text2) }
            if !example, let message = workspace.message { Text(message).font(.subheadline) }
            ForEach(currentReport.followUps ?? []) { answer in
                VStack(alignment: .leading, spacing: 10) {
                    Text(answer.question).font(.headline)
                    Text("\(answer.provider.title) · \(answer.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Theme.text2)
                    ReportDocumentView(document: .init(text: answer.text, facts: report.facts), facts: report.facts)
                }.padding(.vertical, 6)
            }
        }
    }
    private func reset() { consent = false; if !example { workspace.cancel() } }
    private func ask() {
        guard canAsk else { return }
        let asked = question
        workspace.followUp(report: currentReport, question: asked, consent: consent,
            valid: { question == asked && !personalAccount && phase == .active })
        consent = false
    }
}
