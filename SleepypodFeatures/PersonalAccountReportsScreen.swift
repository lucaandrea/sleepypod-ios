import SwiftUI

public struct PersonalAccountReportsScreen: View {
    @Bindable private var model: PersonalReportWorkspace
    private let health: PersonalHealthWorkspace?
    private let connect: @MainActor () async throws -> MorningReportConnection
    private let example: Bool
    @State private var question = "What does my recorded sleep show, and which one small routine experiment could I consider?"
    @State private var confirmRemoval = false
    @FocusState private var questionFocused: Bool
    @Environment(\.scenePhase) private var phase

    public init(model: PersonalReportWorkspace, health: PersonalHealthWorkspace,
                connect: @escaping @MainActor () async throws -> MorningReportConnection) {
        self.model = model; self.health = health; self.connect = connect; example = false
    }
    init(model: PersonalReportWorkspace, example: Bool,
         connect: @escaping @MainActor () async throws -> MorningReportConnection = { throw MorningReportSharingFailure.unavailable }) {
        self.model = model; self.example = example; health = nil
        self.connect = connect
    }

    public var body: some View {
        FeaturePage(title: "Your personal reports") {
            if phase != .active || !model.available { unavailable }
            else {
                if example { Label("Example · no Health or network access", systemImage: "play.circle").font(.subheadline) }
                Text("Reports for \(model.displayName)").font(.title2.bold()).accessibilityIdentifier("personalReports.person")
                if let latest = model.records.first {
                    MorningBriefContent(report: latest.report, compact: true)
                    NavigationLink("Open your latest report") {
                        PersonalAccountReportDetail(model: model, reportID: latest.id, connect: connect, example: example)
                    }.buttonStyle(FeatureActionButtonStyle(primary: true)).accessibilityIdentifier("personalReports.latest")
                } else {
                    Text("Your first report").font(.headline)
                    Text("Start with your own Health history. Review the calculated summary, then ask your chosen model for an interpretation.")
                        .foregroundStyle(Theme.text2)
                }
                GroupedCard {
                    NavigationLink { PersonalReportSettingsScreen(model: model) } label: {
                        SettingsRow("Your model", icon: "sparkles", chevron: true) { RowValue(model.preferences.provider.title) }
                    }.accessibilityIdentifier("personalReports.models")
                    if let health {
                        NavigationLink { PersonalHealthScreen(model: health) } label: {
                            SettingsRow("Your Health history", icon: "heart", chevron: true)
                        }.accessibilityIdentifier("personalReports.health")
                    }
                }.buttonStyle(.plain)
                FeatureSection(title: "Create a report") {
                    PersonalReportQuestionField(title: "What would you like to understand?", text: $question, focused: $questionFocused)
                        .disabled(model.busy).accessibilityIdentifier("personalReports.question")
                    Button("Review report request") { questionFocused = false; model.prepare(question: question) }
                        .buttonStyle(FeatureActionButtonStyle(primary: true))
                        .disabled(!model.mayRequest || !model.hasHealthEvidence)
                        .accessibilityIdentifier("personalReports.review")
                    if !model.hasHealthEvidence {
                        Text("Open Your Health history above, connect your own records and choose a sleep source.")
                            .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("personalReports.needsHealth")
                    }
                    if !model.mayRequest && !model.busy {
                        Text("Saved reports remain readable. Reconnect to your personal account to create a new report.")
                            .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("personalReports.offline")
                    }
                }
                PersonalReportRequestSection(model: model)
                if model.records.count > 1 {
                    FeatureSection(title: "Previous reports") {
                        ForEach(model.records.dropFirst()) { record in
                            NavigationLink(record.report.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                                PersonalAccountReportDetail(model: model, reportID: record.id, connect: connect, example: example)
                            }
                        }
                    }
                }
                Text("Reports and model keys stay separate from other sleepers and the household owner. Creating a report does not change the bed.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if !model.records.isEmpty {
                    Button("Remove personal reports from this device", role: .destructive) { confirmRemoval = true }
                        .foregroundStyle(Theme.red).frame(minHeight: 44).accessibilityIdentifier("personalReports.remove")
                }
            }
        }.frame(maxWidth: 720).frame(maxWidth: .infinity).scrollDismissesKeyboard(.interactively)
            .navigationTitle("Your reports").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if questionFocused { Spacer(); Button("Done") { questionFocused = false } }
                }
            }
            .task { model.restore() }
            .onChange(of: question) { model.cancel() }
            .onChange(of: phase) { if phase != .active { model.cancel() } }
            .onDisappear { questionFocused = false; model.cancel() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in model.invalidate() }
            .alert("Remove these personal reports?", isPresented: $confirmRemoval) {
                Button("Remove reports", role: .destructive) { model.forgetReports() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes this account’s reports from this device. Health imports, keys, shared web copies and monthly usage remain.") }
    }
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 16) {
            ContentUnavailableView("Your reports are private", systemImage: "lock",
                description: Text("Unlock this device and reopen your personal account. A saved report that cannot be read will not be replaced."))
            if let message = model.message { Text(message).font(.subheadline) }
            Button("Try reading saved reports") { model.restore() }.buttonStyle(FeatureActionButtonStyle())
        }
    }
}

/// Shares the report question style while giving its parent explicit keyboard control.
struct PersonalReportQuestionField: View {
    let title: String
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var body: some View {
        FeatureField(title: title) {
            TextField(title, text: $text, axis: .vertical)
                .lineLimit(3...8).padding(12)
                .background(Theme.active, in: RoundedRectangle(cornerRadius: 13))
                .focused($focused).accessibilityLabel(title)
                .onChange(of: text) { text = InputText.limit(text, to: 600) }
        }
    }
}

struct PersonalReportRequestSection: View {
    @Bindable var model: PersonalReportWorkspace
    @State private var consent = false
    var body: some View {
        Group {
            if let review = model.review {
                FeatureSection(title: review.previous == nil ? "Review this report" : "Review this answer") {
                    Text(review.preferences.destination).font(.headline).accessibilityIdentifier("personalReports.destination")
                    Text(review.preferences.model).font(.subheadline).foregroundStyle(Theme.text2)
                    Text(review.question).font(.body)
                    Text("Source: \(review.source)").font(.subheadline)
                    DisclosureGroup("Calculated evidence in this request") {
                        ForEach(review.facts) { Text($0.text).font(.subheadline).padding(.vertical, 4) }
                    }.accessibilityIdentifier("personalReports.evidence")
                    if review.preferences.provider.leavesDevice {
                        Toggle("Send this calculated evidence and question to \(review.preferences.destination) for this request", isOn: $consent)
                            .accessibilityIdentifier("personalReports.consent")
                        Text("Raw Health samples and provider keys are not in the prompt. The receiving provider’s data policy applies.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    } else {
                        Text("Apple’s model will use this summary on this device.").font(.subheadline)
                    }
                    Button(review.previous == nil ? "Create my report" : "Ask about this report") {
                        let approved = consent; consent = false
                        Task { await model.generate(confirmedSharing: approved) }
                    }.buttonStyle(FeatureActionButtonStyle(primary: true))
                        .disabled(model.busy || review.preferences.provider.leavesDevice && !consent)
                        .accessibilityIdentifier("personalReports.generate")
                    Button("Keep editing") { consent = false; model.discardReview() }.frame(minHeight: 44)
                    Text("Review expires at \(review.expiresAt.formatted(date: .omitted, time: .shortened)). No bed settings change.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            if model.busy {
                ProgressView("Working on your request…")
                Button("Cancel request") { model.cancel() }.frame(minHeight: 44).accessibilityIdentifier("personalReports.cancel")
            }
            if let message = model.message {
                Text(message).font(.subheadline).accessibilityIdentifier("personalReports.message").accessibilityAddTraits(.updatesFrequently)
            }
        }.onChange(of: model.review?.id) { consent = false }
            .onDisappear { consent = false }
    }
}
