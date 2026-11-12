import SwiftUI

struct ReportWebSharingScreen: View {
    let report: PersonalSleepReport
    var example = false
    @State var workspace = MorningReportSharingWorkspace()
    @State private var consent = false
    @State private var confirmingWithdrawal = false
    @Environment(\.scenePhase) private var phase
    @AppStorage(PersonalWorkspaceBoundary.preferenceKey) private var personal = false
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("household.boundaryRevision") private var householdRevision = ""
    private var allowed: Bool { phase == .active && (example || !personal && !AppMode.isDemo) }
    private var context: String { "\(phase)|\(personal)|\(ownerRevision)|\(address)|\(backend)|\(householdRevision)|\(report.id)|\(report.followUps?.count ?? 0)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !allowed { ContentUnavailableView("Your report is private", systemImage: "lock") }
                else {
                    if example { Label("Example · no personal data or network access", systemImage: "info.circle").font(.subheadline).foregroundStyle(Theme.reportAccent) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Read this report in your browser").font(.title2.bold())
                        Text("Share a copy of this saved report with your Pod’s authenticated web app. Your original stays on this device.")
                            .font(.body).foregroundStyle(Theme.text2)
                        Text("Report from \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline).foregroundStyle(Theme.text2)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Label(statusTitle, systemImage: statusIcon).font(.headline).accessibilityIdentifier("report.share.status")
                        if let address = workspace.address {
                            Text(address).font(.subheadline).foregroundStyle(Theme.text2).textSelection(.enabled)
                                .accessibilityIdentifier("report.share.address")
                        }
                        if let receipt = workspace.receipt {
                            Text("Pod confirmed \(Date(timeIntervalSince1970: Double(receipt.updatedAt) / 1000).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(Theme.text2)
                        }
                        Button(workspace.busy ? "Checking…" : "Refresh sharing status") { Task { await refresh() } }
                            .buttonStyle(FeatureActionButtonStyle()).disabled(workspace.busy).accessibilityIdentifier("report.share.refresh")
                        if let message = workspace.message { Text(message).font(.subheadline).accessibilityIdentifier("report.share.message") }
                    }
                    if workspace.status == .withdrawn {
                        Text("This shared copy has been withdrawn. It cannot return through a delayed sync. You can create a new report when you want to share again.")
                            .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("report.share.withdrawnDetails")
                    }
                    if workspace.canShare {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("What is shared").font(.headline)
                            Text("The report’s text, calculated facts, comparison chart and saved answers. Provider keys and raw Health samples are not included.")
                                .font(.subheadline).foregroundStyle(Theme.text2)
                            Text("People with your Pod’s owner key can read this copy. Pod administrators and backups also have access.")
                                .font(.subheadline).foregroundStyle(Theme.text2)
                            Toggle("Share this report with my Pod’s web app", isOn: $consent).accessibilityIdentifier("report.share.consent")
                            Button(workspace.needsUpdate ? "Update shared answers" : "Share report") {
                                let approved = consent; consent = false
                                Task { await workspace.share(consent: approved, valid: { allowed }) }
                            }.buttonStyle(FeatureActionButtonStyle(primary: true)).disabled(!consent || workspace.busy).accessibilityIdentifier("report.share.send")
                        }
                    }
                    if workspace.canWithdraw {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Remove the web copy").font(.headline)
                            Text("Withdrawal removes this report from the Pod’s shared library. It does not erase your original on this device or existing backups.")
                                .font(.subheadline).foregroundStyle(Theme.text2)
                            Button("Withdraw shared copy", role: .destructive) { confirmingWithdrawal = true }
                                .buttonStyle(FeatureActionButtonStyle()).disabled(workspace.busy).accessibilityIdentifier("report.share.withdraw")
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .center)
        }.background(Theme.background).navigationTitle("Web copy").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("report.share.scroll")
            .task(id: context) { await refresh() }
            .onDisappear { consent = false; workspace.suspend() }
            .alert("Withdraw this shared copy?", isPresented: $confirmingWithdrawal) {
                Button("Cancel", role: .cancel) {}
                Button("Withdraw", role: .destructive) { Task { await workspace.withdraw(valid: { allowed }) } }
            } message: { Text("The Pod’s web copy will be removed. Your original report and existing backups remain.") }
    }
    private var statusTitle: String {
        if workspace.busy { return "Checking the Pod" }
        switch workspace.status {
        case .unchecked: return "Sharing status not checked"
        case .notShared: return "Not shared with this Pod"
        case .shared: return workspace.needsUpdate ? "New answers ready to share" : "Shared with your Pod"
        case .withdrawn: return "Web copy withdrawn"
        case .uncertain: return "Sharing result unconfirmed"
        }
    }
    private var statusIcon: String {
        switch workspace.status {
        case .shared: "checkmark.circle"
        case .withdrawn, .notShared: "lock"
        case .uncertain: "exclamationmark.circle"
        case .unchecked: "globe"
        }
    }
    private func refresh() async {
        consent = false; confirmingWithdrawal = false; workspace.suspend()
        if allowed { await workspace.refresh(report) }
    }
}
