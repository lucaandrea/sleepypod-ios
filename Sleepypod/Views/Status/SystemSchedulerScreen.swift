import SwiftUI

struct SystemSchedulerScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SystemSchedulerWorkspace
    init(client: (any SystemSchedulerClient)? = nil) {
        let chosen = client ?? (APIBackend.current.isDemo ? DemoSystemSchedulerClient() : CoreSystemSchedulerClient())
        _model = State(initialValue: SystemSchedulerWorkspace(client: chosen))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated scheduler jobs").font(.footnote).foregroundStyle(Theme.amber) }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber) }
                if model.loading { ProgressView("Reading scheduled jobs…") }
                if let timeline = model.timeline {
                    summary(timeline)
                    if model.error != nil { Text("Showing the last successful snapshot. Refresh to check current jobs.").foregroundStyle(Theme.amber) }
                    if !timeline.validTimezone { Text("The Pod returned an unknown timezone. Times below use UTC.").foregroundStyle(Theme.amber) }
                    SystemSchedulerNightCard(timeline: timeline)
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Next up").font(.headline)
                            if timeline.upcoming.isEmpty { Text("No occurrences in the returned eight-day window.").foregroundStyle(Theme.text2) }
                            ForEach(Array(timeline.upcoming.prefix(5)), id: \.identity) { occurrence in
                                SystemSchedulerOccurrenceRow(occurrence: occurrence, timeline: timeline)
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                } else if !model.loading {
                    ContentUnavailableView("Scheduler unavailable", systemImage: "calendar.badge.exclamationmark", description: Text("Refresh when your controller is reachable."))
                }
                Button("Refresh scheduler") { Task { await model.load() } }.disabled(model.loading)
            }.padding(16)
        }.accessibilityIdentifier("scheduler.content").background(Theme.background).navigationTitle("Scheduler").navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await model.load()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                } while !Task.isCancelled
            }
    }
    private func summary(_ timeline: SystemSchedulerTimeline) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(status(timeline), systemImage: timeline.enabled ? "calendar.badge.clock" : "pause.circle")
                    .font(.headline).foregroundStyle(timeline.enabled && model.health?.scheduler.drift?.drifted != true ? Theme.green : Theme.amber)
                if let drift = model.health?.scheduler.drift, drift.drifted {
                    Text("\(drift.dbScheduleCount) scheduled entries · \(drift.schedulerJobCount) loaded").foregroundStyle(Theme.amber)
                }
                Text("\(timeline.jobs.count) loaded jobs").font(.subheadline)
                NavigationLink { SystemSchedulerJobsScreen(timeline: timeline) } label: { Label("All jobs", systemImage: "list.bullet") }
                    .accessibilityIdentifier("scheduler.allJobs")
                ForEach(SystemSchedulerTimeline.Group.allCases) { group in
                    let count = timeline.jobs.filter { $0.group == group }.count
                    if count > 0 { LabeledContent(group.rawValue, value: "\(count)").font(.footnote) }
                }
                Text("Pod time: \(timeline.clock(timeline.date, includeDay: true)) · \(timeline.timezone)").font(.caption).foregroundStyle(Theme.text2)
                if let error = model.healthError { Text("Sync check unavailable: \(error)").font(.footnote).foregroundStyle(Theme.amber) }
                Text("Loaded jobs and planned occurrences. This view does not report completed executions or move the bed.").font(.footnote).foregroundStyle(Theme.text2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func status(_ timeline: SystemSchedulerTimeline) -> String {
        if !timeline.enabled { return "Scheduler disabled" }
        if let drift = model.health?.scheduler.drift { return drift.drifted ? "Schedule drift detected" : "Scheduler in sync" }
        return "Scheduler enabled · sync unknown"
    }
}

struct SystemSchedulerOccurrenceRow: View {
    @Environment(SettingsManager.self) private var settings
    let occurrence: SystemSchedulerTimeline.Occurrence
    let timeline: SystemSchedulerTimeline
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(occurrence.side.map { settings.sideName(for: $0) } ?? "Pod") · \(SystemSchedulerTimeline.label(occurrence.type))").font(.subheadline.weight(.medium))
            if let temperature = occurrence.targetTempF {
                Text(TemperatureConversion.displayTemp(Int(temperature.rounded()), format: settings.temperatureFormat)).foregroundStyle(TempColor.forScheduled(Int(temperature.rounded())))
            } else if occurrence.type == "run_once" { Text("End session").foregroundStyle(Theme.text2) }
            if let brightness = occurrence.brightness { Text("Brightness \(brightness.formatted())%").foregroundStyle(Theme.text2) }
            Text(timeline.clock(occurrence.date, includeDay: true)).font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
