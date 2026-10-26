import SwiftUI

struct SystemSchedulerJobsScreen: View {
    @Environment(SettingsManager.self) private var settings
    let timeline: SystemSchedulerTimeline
    @State private var search = ""
    @State private var group: SystemSchedulerTimeline.Group?
    @FocusState private var searchFocused: Bool
    private var jobs: [SystemSchedulerTimeline.Job] {
        timeline.jobs.filter {
            (group == nil || $0.group == group) && (search.isEmpty || [$0.id, $0.type, SystemSchedulerTimeline.label($0.type), $0.schedule, $0.side.map { settings.sideName(for: $0) } ?? "Pod"].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }.sorted { ($0.nextRun ?? .infinity) < ($1.nextRun ?? .infinity) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Job type", selection: $group) {
                    Text("All types").tag(SystemSchedulerTimeline.Group?.none)
                    ForEach(SystemSchedulerTimeline.Group.allCases) { group in Text(group.rawValue).tag(Optional(group)) }
                }.accessibilityIdentifier("scheduler.jobGroup")
                TextField("Search jobs", text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityIdentifier("scheduler.search")
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                Text("\(jobs.count) matching \(jobs.count == 1 ? "job" : "jobs")").font(.footnote).accessibilityIdentifier("scheduler.jobCount")
                Text("Snapshot at \(timeline.clock(timeline.date, includeDay: true)) · \(timeline.timezone). Return to Scheduler to refresh.").font(.caption).foregroundStyle(Theme.text2)
                ForEach(jobs) { job in
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(job.side.map { settings.sideName(for: $0) } ?? "Pod") · \(SystemSchedulerTimeline.label(job.type))").font(.headline)
                            if let target = job.targetTempF { Text(TemperatureConversion.displayTemp(Int(target.rounded()), format: settings.temperatureFormat)).foregroundStyle(TempColor.forScheduled(Int(target.rounded()))) }
                            if let brightness = job.brightness { Text("Brightness \(brightness.formatted())%") }
                            Text(timeline.recurrence(job)).font(.subheadline)
                            Text(job.nextRun.map { "Next: " + timeline.clock(Date(timeIntervalSince1970: $0 / 1000), includeDay: true) } ?? "No next execution reported").font(.footnote).foregroundStyle(Theme.text2)
                            DisclosureGroup("Schedule details") {
                                Text("Job: \(job.id)\nSchedule: \(job.schedule)\n\(job.oneTime ? "One time" : "Recurring")").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
                if jobs.isEmpty { ContentUnavailableView.search(text: search) }
            }.padding(16)
        }.accessibilityIdentifier("scheduler.jobsContent").background(Theme.background).navigationTitle("All jobs").navigationBarTitleDisplayMode(.inline)
    }
}
