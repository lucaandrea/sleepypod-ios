import SwiftUI

/// Available without a Pod connection: these records belong to the device owner, not the selected bed side.
public struct WatchRecordingAssistantLink: View {
    @State private var workspace = IntelligenceWorkspace.shared
    @AppStorage(PersonalWorkspaceBoundary.preferenceKey) private var personal = false
    public init() {}
    public var body: some View {
        if !personal {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let summary = WatchRecordingSummary(history: WatchRecordingPresentation.history(workspace), now: context.date)
                NavigationLink { WatchRecordingAssistantScreen() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "applewatch").font(.title2).foregroundStyle(Theme.cool)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Watch recording assistant").font(.headline)
                            Text(workspace.healthReadError == nil ? summary.title : "Health refresh needs attention")
                                .font(.caption).foregroundStyle(Theme.text2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text2)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: .rect(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityIdentifier("watch.recording.open")
            }.task { if !AppMode.isDemo { workspace.restore() } }
        }
    }
}

struct WatchRecordingAssistantScreen: View {
    @State private var workspace = IntelligenceWorkspace.shared
    @State private var showSteps = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(PersonalWorkspaceBoundary.preferenceKey) private var personal = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let history = WatchRecordingPresentation.history(workspace)
            let summary = WatchRecordingSummary(history: history, now: context.date)
            FeaturePage(title: "Watch recording") {
                if personal { Text("Open your personal account’s Health tools. The installation owner’s history is not shown here.") }
                else {
                    if AppMode.isDemo { FeatureStatus(title: "EXAMPLE · NOT YOUR HEALTH DATA", tone: .warning) }
                    overview(summary)
                    refreshControls
                    troubleshooting
                    coverage(summary, timeZone: history.timeZone)
                }
            }
        }
        .task { if !personal, !AppMode.isDemo { workspace.restore() } }
        .task(id: scenePhase) {
            guard scenePhase == .active, !personal else { return }
            await workspace.refreshOnActivation()
        }
    }
    private func overview(_ summary: WatchRecordingSummary) -> some View {
        FeatureSection(title: "Your Watch sleep") {
            Group {
                if dynamicTypeSize.isAccessibilitySize { Text(summary.title) }
                else { Label(summary.title, systemImage: "applewatch") }
            }.font(.title3.bold()).accessibilityIdentifier("watch.recording.status")
            Text(summary.explanation).foregroundStyle(Theme.text2)
            if let imported = summary.importedAt {
                Text("Last successful Health read: \(imported.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.subheadline).accessibilityIdentifier("watch.recording.imported")
            }
            if let latest = summary.latest {
                Label("Latest returned Watch sleep: \(latest.end.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.subheadline)
            }
            if let error = workspace.healthReadError, !AppMode.isDemo {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Theme.amber)
                    .accessibilityIdentifier("watch.recording.error")
            }
            Text("Private on this device. No cloud report, model training or bed adjustment happens here.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private func coverage(_ summary: WatchRecordingSummary, timeZone: String) -> some View {
        FeatureSection(title: "Last seven mornings") {
            Text("Sleep intervals returned by Health, grouped noon to noon in \(timeZone). Naps can be included. Blank days remain unknown.")
                .font(.caption).foregroundStyle(Theme.text2)
            ForEach(summary.days.reversed()) { day in
                VStack(alignment: .leading, spacing: 6) {
                    Text(day.wakeDate, format: .dateTime.weekday(.wide).month(.abbreviated).day()).font(.subheadline.bold())
                    if let night = day.night {
                        let minutes = Int(night.asleepMinutes.rounded())
                        Label("\(minutes / 60)h \(minutes % 60)m labelled asleep", systemImage: "moon.stars")
                            .foregroundStyle(Theme.cool)
                        Text("\(night.start.formatted(date: .omitted, time: .shortened)) – \(night.end.formatted(date: .omitted, time: .shortened)) · first to last interval")
                            .font(.caption).foregroundStyle(Theme.text2)
                    } else {
                        Label("No returned sleep · unknown", systemImage: "questionmark.circle")
                            .font(.subheadline).foregroundStyle(Theme.text2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
            }.environment(\.timeZone, TimeZone(identifier: timeZone) ?? .current)
            Text("Time between intervals may be awake or unrecorded. This view does not certify a complete night or measure Watch wear time.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private var refreshControls: some View {
        FeatureSection(title: "Keep history up to date") {
            Button(workspace.busy ? "Working…" : "Read Health now") { Task { await workspace.importHistory() } }
                .buttonStyle(PrimaryButtonStyle()).disabled(workspace.busy || AppMode.isDemo)
                .accessibilityIdentifier("watch.recording.refresh")
            Toggle("Automatic history refresh", isOn: $workspace.refreshHistory)
                .tint(Theme.green).disabled(AppMode.isDemo).accessibilityIdentifier("watch.recording.automatic")
            Text("After you connect Health, sleepypod checks at most every 30 minutes from 4 a.m. to 2 p.m. in this device’s timezone, and every six hours otherwise. iOS chooses background opportunities; imports cannot be guaranteed at a set time or while locked.")
                .font(.caption).foregroundStyle(Theme.text2)
            Text("Watch references sent to your Pod are a separate, reviewed import in the sleep comparison tools. This assistant only refreshes your private local history.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private var troubleshooting: some View {
        FeatureSection(title: "If a night is missing") {
            DisclosureGroup("Check recording, sync and access", isExpanded: $showSteps) {
                VStack(alignment: .leading, spacing: 16) {
                    step("1. Check Apple Health", "On the paired iPhone, open Health → Search → Sleep. Check the date and data source. If that night is present there, unlock the phone, let the Watch sync, then return here and read again.")
                    step("2. Check the Watch", "In the Watch app on your iPhone, open Sleep and check Track Sleep with Apple Watch. Charge to at least 30% before bed and wear it comfortably. Charging reminders can help.")
                    step("3. Review sleepypod’s read access", "In Health, tap your profile → Apps → sleepypod and review Sleep access. Labels may differ by iOS version. Empty results cannot tell us whether access is restricted or no records exist.")
                    step("4. Allow a morning retry", "Keep the Watch near its paired iPhone. Open sleepypod after unlocking and choose Read Health now. A record that arrives later replaces the local import; it is never counted twice.")
                    Link("Apple’s sleep recording guide", destination: URL(string: "https://support.apple.com/en-us/108906")!)
                }.padding(.top, 12)
            }.accessibilityIdentifier("watch.recording.help")
        }
    }
    private func step(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(Theme.text2)
        }
    }
}

enum WatchRecordingPresentation {
    @MainActor static func history(_ workspace: IntelligenceWorkspace) -> HealthHistory {
        guard AppMode.isDemo else { return workspace.archive.history }
        // Practice mode cannot read the device owner's archived Health records.
        #if DEBUG
        if UserDefaults.standard.string(forKey: "uiWatchRecording") == "available" {
            let now = Date.now
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now) ?? now
            let end = min(morning, now.addingTimeInterval(-600))
            return HealthHistoryAnalyzer.build(samples: [.init(start: end.addingTimeInterval(-7 * 3600), end: end,
                sourceID: "example-watch", sourceName: "Example Watch", stage: .core, recordedByWatch: true)], now: now, timeZone: .current)
        }
        #endif
        return HealthHistory(importedAt: .now, timeZone: TimeZone.current.identifier, sources: [], ignoredSamples: 0, watchNights: [])
    }
}
