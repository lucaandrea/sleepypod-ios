import SwiftUI

struct PersonalAccountReportDetail: View {
    @Bindable var model: PersonalReportWorkspace
    let reportID: UUID
    let connect: @MainActor () async throws -> MorningReportConnection
    var example = false
    @State private var question = ""
    @FocusState private var questionFocused: Bool
    @Environment(\.scenePhase) private var phase
    private var record: PersonalReportRecord? { model.records.first { $0.id == reportID } }

    var body: some View {
        FeaturePage(title: "Your morning brief") {
            if phase == .active, let record {
                MorningBriefContent(report: record.report)
                if let experiment = ReportDocument(text: record.report.text, facts: record.report.facts).experiment {
                    FeatureSection(title: "One idea to consider", badge: "AI suggestion · not started") {
                        ReportDocumentView(document: experiment, facts: record.report.facts)
                    }
                }
                DisclosureGroup("Full interpretation and evidence") { PersonalReportCard(report: record.report) }
                    .accessibilityIdentifier("personalReports.fullReport")
                FeatureSection(title: "Ask about this report") {
                    Text("Answers use this report’s original evidence. They do not read new nights or change the bed.")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    PersonalReportQuestionField(title: "Your question", text: $question, focused: $questionFocused).disabled(model.busy)
                        .accessibilityIdentifier("personalReports.followUp")
                    Button("Review my question") { questionFocused = false; model.prepare(question: question, reportID: reportID) }
                        .buttonStyle(FeatureActionButtonStyle(primary: true))
                        .disabled(!model.mayRequest || (record.report.followUps?.count ?? 0) >= 10)
                        .accessibilityIdentifier("personalReports.reviewAnswer")
                    Text("Up to ten answers stay with this report.").font(.footnote).foregroundStyle(Theme.text2)
                }
                PersonalReportRequestSection(model: model)
                ForEach(record.report.followUps ?? []) { answer in
                    FeatureSection(title: answer.question) {
                        Text("AI interpretation").font(.subheadline).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("personalReports.answerProvenance")
                        Text("\(answer.provider.title) · \(answer.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(Theme.text2)
                        ReportDocumentView(document: .init(text: answer.text, facts: record.report.facts), facts: record.report.facts)
                    }
                }
                NavigationLink("Read this report in your browser") {
                    ReportWebSharingScreen(report: record.report, example: example,
                        workspace: MorningReportSharingWorkspace(connect: connect),
                        personalAccess: { model.available && model.records.contains(record) })
                }.buttonStyle(FeatureActionButtonStyle()).accessibilityIdentifier("personalReports.webCopy")
            } else {
                ContentUnavailableView("Reopen your personal reports", systemImage: "lock",
                    description: Text("This report was removed or your account access changed."))
            }
        }.frame(maxWidth: 720).frame(maxWidth: .infinity).scrollDismissesKeyboard(.interactively)
            .navigationTitle("Morning brief").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if questionFocused { Spacer(); Button("Done") { questionFocused = false } }
                }
            }
            .onChange(of: question) { model.cancel() }
            .onChange(of: phase) { if phase != .active { model.cancel() } }
            .onDisappear { questionFocused = false; model.cancel() }
    }
}
