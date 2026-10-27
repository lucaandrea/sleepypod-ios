import SwiftUI
import Charts
import FreeSleepKit

struct AnalysisHistoryCard: View {
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings
    @Environment(HealthSyncService.self) private var health
    @Environment(StageModelStore.self) private var models
    @Environment(\.scenePhase) private var phase
    @State private var history = AnalysisHistoryWorkspace()
    @State private var healthNights: Int?
    @State private var healthMessage: String?
    @State private var refreshID = UUID()
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 130
    private var scope: String { "\(OwnerConnection.revision)|\(profile.defaultSide)|\(health.enabled)|\(health.preferences.readSleep)|\(phase)" }
    private var ownRecords: [AnalysisHistoryRecord] { history.records.filter { $0.side == profile.defaultSide } }
    private var latest: SleepRecord? { history.currentRecords.filter { $0.side == profile.defaultSide.rawValue && !$0.isOngoing }.max { $0.enteredBedDate < $1.enteredBedDate } }
    private var calendar: Calendar { SleepCalendar.calendar(timeZone: settings.timeZone) }

    var body: some View {
        GroupedSection("YOUR SLEEP DATA") {
            GroupedCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(history.loaded ? history.totalRecordCount.formatted() : "—").font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                        Text("history records").foregroundStyle(Theme.text2)
                    }.accessibilityIdentifier("analysis.records")
                    Text("\(history.records.count.formatted()) bed sessions · \(history.archive.vitals.count.formatted()) imported vital readings · \(history.archive.movementCount.formatted()) movement records")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    Text("\(settings.sideName(for: profile.defaultSide)) · \(ownRecords.count.formatted()) bed sessions on this iPhone’s side")
                        .font(.caption).foregroundStyle(Theme.text3)
                    if let first = ownRecords.map(\.start).min(), let last = ownRecords.map(\.end).max() {
                        Text("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(Theme.text3)
                    }
                    if !ownRecords.isEmpty { coverageChart }
                    if history.loading { ProgressView(history.progress).font(.footnote) }
                    ForEach(history.errors, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
                    Text(history.errors.isEmpty
                         ? "Includes available Pod sessions and imported measurements. Time in bed and vital readings do not establish sleep stages."
                         : "Some history could not be read. The count includes only records loaded successfully; refresh to try again.")
                        .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Refresh all history", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(history.loading).accessibilityIdentifier("analysis.refresh")
                }.padding(16)
                Divider()
                NavigationLink { ImportedHistoryScreen(side: profile.defaultSide) } label: {
                    SettingsRow("Imported bed history", subtitle: "Browse original records and measurements", icon: "archivebox", chevron: true)
                }
            }
            if !history.archive.vitals.isEmpty {
                AnalysisMeasurementsCard(records: history.archive.vitals.filter { $0.side == profile.defaultSide },
                                         sideName: settings.sideName(for: profile.defaultSide), timeZone: settings.timeZone)
            }
            GroupedCard {
                NavigationLink { HealthAccessView() } label: {
                    SettingsRow("Apple Health", subtitle: healthMessage ?? "Reading permitted sleep history…", icon: "heart", iconColor: Theme.red, chevron: true)
                }.accessibilityIdentifier("analysis.health")
                if let healthNights {
                    SettingsRow("Watch reference nights", subtitle: "For the person using this iPhone", icon: "applewatch") { RowValue(healthNights.formatted(), mono: true) }
                }
                NavigationLink { PodFeatureScreen(.healthHistory, side: profile.defaultSide.rawValue) } label: {
                    SettingsRow("Health trends", subtitle: "Sleep, heart rate, HRV and breathing", icon: "chart.xyaxis.line", chevron: true)
                }
            }
            if let latest {
                NavigationLink { StageComparisonView(record: latest, side: profile.defaultSide) } label: {
                    SettingsRow("Compare and train models", subtitle: "Check Pod readings against Apple Watch nights", icon: "brain", iconColor: Theme.cool, chevron: true)
                }.cardStyle(vertical: 0, horizontal: 0).accessibilityIdentifier("analysis.compare")
            }
            Text("Sleep-stage analysis describes your nights. Overnight temperature changes run on the Pod through schedules and Personal comfort. A personal stage model needs matching Pod signals and Apple Watch stages; the archive count alone does not establish training readiness.")
                .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: scope) { if phase == .active { await refresh() } else { history.cancel() } }
        .onDisappear { refreshID = UUID(); history.cancel() }
    }

    private var coverageChart: some View {
        let grouped = Dictionary(grouping: ownRecords) { calendar.dateInterval(of: .month, for: $0.start)?.start ?? $0.start }
        let months = grouped.keys.sorted()
        return Chart(months, id: \.self) { month in
            BarMark(x: .value("Month", month, unit: .month), y: .value("Bed records", grouped[month]?.count ?? 0))
                .foregroundStyle(Theme.cool)
        }.chartYAxisLabel("Records").frame(height: chartHeight)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .accessibilityLabel("Bed record coverage by month")
    }

    private func refresh() async {
        refreshID = UUID(); let operation = refreshID, original = scope
        healthNights = nil; healthMessage = nil
        let archive: (any ImportedHistoryClient)? = APIBackend.current.isDemo ? DemoImportedHistoryClient(scenario: "loaded")
            : APIBackend.current == .sleepypodCore ? (try? CoreRESTClient.configured()).map { CoreImportedHistoryClient(transport: $0) } : nil
        await history.load(api: APIBackend.current.createClient(), archive: archive)
        guard operation == refreshID, original == scope, !Task.isCancelled else { return }
        if !APIBackend.current.isDemo { await models.refreshPodModel(api: APIBackend.current.createClient(), side: profile.defaultSide) }
        guard operation == refreshID, original == scope, !Task.isCancelled else { return }
        guard health.enabled && health.preferences.readSleep else { healthMessage = "Allow sleep history to compare your nights"; return }
        guard !APIBackend.current.isDemo else { healthMessage = "Demo does not read your Health records"; return }
        do {
            let samples = try await health.analysisSleepSamples(start: Date(timeIntervalSince1970: 0), end: .now)
            guard operation == refreshID, original == scope, !Task.isCancelled else { return }
            let stages = StageComparison.watchStages(samples.map { (source: StageComparison.HealthSource($0), value: $0.value, start: $0.startDate, end: $0.endDate) })
            healthNights = WatchComparison.sessions(stages).count
            healthMessage = samples.isEmpty ? "No readable sleep history · check Health access" : "\(samples.count.formatted()) readable sleep samples"
        } catch { if operation == refreshID, original == scope { healthMessage = "Health history unavailable · \(error.localizedDescription)" } }
    }
}
