import Charts
import SwiftUI

struct TemperatureHistoryLink: View {
    var body: some View {
        NavigationLink { TemperatureHistoryScreen() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Schedule and bed history").font(.headline)
                    Text("Last night, tonight, Run Once and Autopilot").font(.footnote).foregroundStyle(Theme.text2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text2)
            }.cardStyle()
        }.buttonStyle(.plain).accessibilityIdentifier("temperature.history.open")
    }
}

struct TemperatureHistoryScreen: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedules
    @Environment(CurveWorkspace.self) private var curves
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    @AppStorage("podURL") private var podURL = ""
    @AppStorage("podIPAddress") private var podIP = ""
    @AppStorage("apiBackend") private var backend = ""
    @State private var workspace = TemperatureHistoryWorkspace()
    @State private var automation: AutomationWorkspace?
    @State private var position = 0.5
    @State private var now = Date.now
    @State private var reload = 0
    @State private var setupError: String?
    private var scope: String { "\(backend)|\(podURL)|\(podIP)|\(ownerRevision)" }
    private var history: TemperatureHistory { .init(schedules: schedules.error == nil ? schedules.schedules : nil, timezone: settings.timeZone, now: now) }
    private var selected: Date { history.range.lowerBound.addingTimeInterval(position * history.range.upperBound.timeIntervalSince(history.range.lowerBound)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if APIBackend.current.isDemo { Text("DEMO · synthetic history and configuration").font(.footnote).foregroundStyle(Theme.amber) }
                Text("Saved targets, recorded power and in-bed intervals use the same clock. Gaps stay visible. Inspecting this page never changes the bed.").font(.footnote).foregroundStyle(Theme.text2)
                Text("\(clock(history.range.lowerBound)) – \(clock(history.range.upperBound)) · \(settings.timeZone)").font(.caption).foregroundStyle(Theme.text2)
                if let setupError { Text(setupError).font(.footnote).foregroundStyle(Theme.amber) }
                if let observed = workspace.observedAt { Text("History read \(clock(observed))").font(.caption).foregroundStyle(Theme.text2) }
                Button(workspace.loading ? "Refreshing…" : "Refresh history") { reload += 1 }.disabled(workspace.loading).accessibilityIdentifier("temperature.history.refresh")
                if let error = schedules.error { Text("Saved schedules unavailable: \(error)").font(.footnote).foregroundStyle(Theme.amber) }
                ForEach(Side.allCases) { side in sideCard(side) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Inspect \(clock(selected))").font(.subheadline.monospacedDigit()).accessibilityIdentifier("temperature.history.clock")
                    Slider(value: $position, in: 0...1).accessibilityLabel("Inspect schedule and bed history").accessibilityValue(clock(selected)).accessibilityIdentifier("temperature.history.slider")
                    Text("Saved schedules can change after a night. They are a projection of the current plan, not proof of the temperatures delivered then.").font(.caption).foregroundStyle(Theme.text2)
                }.cardStyle()
                if let model = automation {
                    DisclosureGroup("Tonight’s Autopilot plan and recorded decisions") {
                        if let error = model.error ?? model.tonightError ?? model.timelineError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                        AutomationTonightTimeline(timeline: .init(schedules: schedules.error == nil ? schedules.schedules : nil, rules: model.ready ? model.rules : [], timezone: settings.timeZone, now: now), snapshot: model.tonight, activity: model.timelineActivity, enabled: model.ready ? model.globalEnabled : nil)
                    }
                }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Bed history").navigationBarTitleDisplayMode(.inline)
            .task(id: "\(scope)|\(scenePhase)|\(reload)") {
                guard scenePhase == .active else { return }
                workspace.reset(); automation = nil; setupError = nil; now = .now
                let client: any TemperatureHistoryClient
                if APIBackend.current.isDemo { client = DemoTemperatureHistoryClient(sessions: curves.sessions, unavailable: DebugRoute.temperatureContextScenario == "partial") }
                else if let transport = try? CoreRESTClient.configured() { client = CoreTemperatureHistoryClient(transport: transport) }
                else { setupError = "Connect to your controller to load bed history."; return }
                let model = AutomationWorkspace(client: APIBackend.current.isDemo ? DemoAutomationClient() : CoreAutomationClient())
                automation = model
                await schedules.fetchSchedules()
                async let loaded: Void = workspace.load(client: client, range: history.range, now: now)
                await model.load(); await model.loadTonight(); await model.loadTimelineActivity(timeZone: settings.timeZone)
                await loaded
            }
    }
    private func sideCard(_ side: Side) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.sideName(for: side)).font(.headline)
            let before = selected < history.tonight.range.lowerBound ? history.lastNight : history.tonight
            let inNight = before.range.contains(selected)
            let state = inNight ? before.state(for: side, at: selected) : .init()
            Text(inNight ? "Saved plan · \(targetLabel(state.temperature, powered: state.powered))" : "Between displayed night windows").font(.footnote)
            Chart {
                ForEach([history.lastNight, history.tonight].indices, id: \.self) { night in
                    let timeline = night == 0 ? history.lastNight : history.tonight
                    ForEach(timeline.samples(for: side)) { point in
                        LineMark(x: .value("Time", point.date), y: .value("°F", point.temperature), series: .value("Night", String(night)))
                            .foregroundStyle(Theme.cool).lineStyle(.init(lineWidth: 2))
                    }
                }
                let points = runOnce(side)
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.date), y: .value("°F", point.temperature), series: .value("Run once", "Run Once"))
                        .interpolationMethod(.stepEnd).foregroundStyle(Theme.violet).lineStyle(.init(lineWidth: 2, dash: [4, 3]))
                }
                RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text1)
            }.chartXScale(domain: history.range).chartYScale(domain: 55...110).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 100)
                .accessibilityLabel("Saved targets and active Run Once, \(settings.sideName(for: side))")
            if let problem = workspace.result?.sessions[side]?.error { Text("Run Once unavailable: \(problem)").font(.caption).foregroundStyle(Theme.amber) }
            else if workspace.result?.sessions[side]?.value != nil && runOnce(side).isEmpty { Text("Run Once timing unavailable.").font(.caption).foregroundStyle(Theme.amber) }
            else if let target = TemperatureHistory.runOnceTarget(runOnce(side), at: selected) {
                Text("Run Once · \(TemperatureConversion.displayTemp(Int(target.rounded()), format: settings.temperatureFormat))").font(.footnote).foregroundStyle(Theme.violet)
            } else { Text("No active Run Once at the inspected time").font(.caption).foregroundStyle(Theme.text2) }
            TemperatureActivityRows(result: workspace.result, side: side, range: history.range, observedAt: workspace.observedAt ?? now, selected: selected, timelines: [history.lastNight, history.tonight])
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    private func runOnce(_ side: Side) -> [TemperatureHistory.RunOncePoint] {
        guard let session = workspace.result?.sessions[side]?.value else { return [] }
        return TemperatureHistory.runOnce(session, side: side, timezone: settings.timeZone)
    }
    private func targetLabel(_ temperature: Int?, powered: Bool?) -> String {
        if powered == false { return "Off" }
        return temperature.map { TemperatureConversion.displayTemp($0, format: settings.temperatureFormat) } ?? "Target unavailable"
    }
    private func clock(_ date: Date) -> String { AutomationDates.label(date.timeIntervalSince1970 * 1000, timeZone: settings.timeZone, includeDate: true) }
}

struct TemperatureActivityRows: View {
    @Environment(SettingsManager.self) private var settings
    let result: TemperatureHistoryResult?
    let side: Side
    let range: ClosedRange<Date>
    let observedAt: Date
    var selected: Date?
    var timelines: [TemperatureTimeline] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result {
                if let error = result.thermal.error { problem("Power history", error) }
                else if let thermal = result.thermal.value {
                    lane("Recorded power", intervals: TemperatureHistory.power(thermal, side: side, in: range, now: observedAt), color: Theme.text2)
                    Text("Power coverage: \(AutomationDates.label(thermal.from, timeZone: settings.timeZone, includeDate: true)) – \(AutomationDates.label(thermal.to, timeZone: settings.timeZone, includeDate: true))").font(.caption2).foregroundStyle(Theme.text2)
                }
                if let error = result.records[side]?.error { problem("In-bed history", error) }
                else if let records = result.records[side]?.value {
                    lane("Recorded in bed", intervals: TemperatureHistory.presence(records, side: side, in: range, now: observedAt), color: Theme.green)
                    let presence = TemperatureHistory.presence(records, side: side, in: range, now: observedAt)
                    ForEach(timelines.flatMap { TemperatureHistory.comparisons(timeline: $0, side: side, presence: presence) }) { comparison in
                        Text(comparisonText(comparison)).font(.caption).foregroundStyle(Theme.amber)
                    }
                    if records.count >= 100 { Text("Showing the first 100 sleep records returned for this window.").font(.caption).foregroundStyle(Theme.amber) }
                }
            } else { Text("Loading recorded activity…").font(.caption).foregroundStyle(Theme.text2) }
        }
    }
    private func comparisonText(_ comparison: TemperatureHistory.Comparison) -> String {
        let date = AutomationDates.label(comparison.start.timeIntervalSince1970 * 1000, timeZone: settings.timeZone, includeDate: true)
        return comparison.kind == .laterEntry
            ? "\(date): first recorded entry \(comparison.minutes) min after the first planned target."
            : "\(date): recorded in bed \(comparison.minutes) min past the last planned target."
    }
    private func lane(_ title: String, intervals: [TemperatureHistory.Interval], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            Chart {
                ForEach(intervals) { interval in
                    RectangleMark(xStart: .value("From", interval.start), xEnd: .value("Until", interval.end), yStart: .value("Bottom", 0), yEnd: .value("Top", 1)).foregroundStyle(color)
                }
                if let selected { RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text1) }
            }.chartXScale(domain: range).chartYScale(domain: 0...1).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 16)
                .accessibilityLabel(title).accessibilityValue(summary(intervals))
            Text(summary(intervals)).font(.caption2).foregroundStyle(Theme.text2)
        }
    }
    private func summary(_ intervals: [TemperatureHistory.Interval]) -> String {
        if let selected { return intervals.contains { $0.start <= selected && selected < $0.end } ? "Recorded at the inspected time" : "No recorded interval at the inspected time" }
        return intervals.isEmpty ? "No recorded intervals" : "\(intervals.count) recorded intervals"
    }
    private func problem(_ title: String, _ message: String) -> some View { Text("\(title) unavailable: \(message)").font(.caption).foregroundStyle(Theme.amber) }
}
