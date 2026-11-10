import SwiftUI

/// Reading an existing report requires neither a controller nor a model request.
public struct SavedPersonalReportsScreen: View {
    @State private var reports: [PersonalSleepReport] = []
    @State private var error: String?
    @AppStorage(PersonalWorkspaceBoundary.preferenceKey) private var personalAccount = false

    public init() {}

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if personalAccount {
                    ContentUnavailableView("Owner reports are private", systemImage: "lock")
                } else {
                    Text("Saved on this iPhone. Each report describes the evidence available when it was created.")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    ForEach(reports) { report in PersonalReportCard(report: report) }
                    if reports.isEmpty {
                        ContentUnavailableView("No saved reports", systemImage: "doc.text",
                            description: Text(error ?? "Create a personal report in Sleep when you reconnect. It will be available here afterward."))
                    }
                }
            }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Saved reports")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: personalAccount) {
            reports = []
            guard !personalAccount else { return }
            do { reports = try PersonalIntelligenceStore().read().reports }
            catch { self.error = "Saved reports could not be unlocked. Please try again when this device is unlocked." }
        }
    }
}
