import SwiftUI

/// Show the newest protected report without reading Health or asking a provider to create a new one.
public struct MorningReportPreview: View {
    @State private var report: PersonalSleepReport?
    @State private var loaded = false
    @AppStorage(PersonalWorkspaceBoundary.preferenceKey) private var personalAccount = false
    @Environment(\.scenePhase) private var phase
    public init() {}
    public var body: some View {
        if !personalAccount {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your morning brief").font(.title2.bold())
                if let report, loaded {
                    MorningBriefContent(report: report, compact: true)
                    NavigationLink("Open brief and ask a question") { MorningBriefScreen(report: report) }
                        .buttonStyle(.bordered).accessibilityIdentifier("tonight.brief")
                } else {
                    Text("Review your latest night in Sleep, or open a report already saved on this iPhone.").font(.subheadline).foregroundStyle(Theme.text2)
                }
                NavigationLink("Open saved personal reports") { SavedPersonalReportsScreen() }
                    .buttonStyle(.bordered).accessibilityIdentifier("tonight.reports")
            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                .task(id: "\(personalAccount)|\(phase)") {
                    report = nil; loaded = false
                    guard !personalAccount, phase == .active, !AppMode.isDemo else { return }
                    report = try? PersonalIntelligenceStore().read().reports.sorted { $0.createdAt > $1.createdAt }.first
                    loaded = true
                }
                .onDisappear { report = nil; loaded = false }
        }
    }
}
