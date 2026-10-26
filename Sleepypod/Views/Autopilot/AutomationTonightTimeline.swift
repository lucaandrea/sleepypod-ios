import Charts
import SwiftUI

struct AutomationTonightTimeline: View {
    @Environment(SettingsManager.self) private var settings
    let timeline: AutomationTimeline
    let snapshot: AutomationTonight?
    let activity: AutomationActivity?
    let enabled: Bool?
    @State private var position = 0.0
    private var selected: Date { timeline.schedule.date(at: position) }

    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Night timeline").font(.headline)
                Text("\(clock(timeline.range.lowerBound)) – \(clock(timeline.range.upperBound)) · \(settings.timeZone)").font(.caption).foregroundStyle(Theme.text2)
                Text("Scheduled targets and possible rule windows. Sensor conditions, triggers, cooldowns and controller priorities still apply.").font(.footnote).foregroundStyle(Theme.text2)
                if enabled != true { Text(enabled == false ? "Autopilot is off. Rule windows are shown for reference." : "Autopilot status unavailable.").font(.footnote).foregroundStyle(Theme.amber) }
                ForEach(Side.allCases) { side in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(settings.sideName(for: side)).font(.headline)
                        let state = timeline.schedule.state(for: side, at: selected)
                        Text("Schedule · \(scheduleLabel(state))").font(.footnote)
                        scheduleLane(side)
                        if let hold = (side == .left ? snapshot?.sides.left : snapshot?.sides.right)?.hold,
                           hold.startedAt <= selected.timeIntervalSince1970 * 1000, selected.timeIntervalSince1970 * 1000 < hold.expiresAt {
                            Text("Manual hold · \(TemperatureConversion.displayTemp(Int(hold.temperature.rounded()), format: settings.temperatureFormat)) until \(AutomationDates.label(hold.expiresAt, timeZone: settings.timeZone))").font(.caption).foregroundStyle(Theme.violet)
                        }
                        ForEach(timeline.lanes.filter { AutomationTimeline.affects(side, rule: $0.rule) }) { lane in
                            Text("\(lane.rule.definition.name) · \(lane.rule.definition.mode.rawValue)").font(.caption)
                            ruleLane(lane, side: side)
                            if lane.windows.isEmpty { Text("Outside its time/day conditions tonight.").font(.caption).foregroundStyle(Theme.text2) }
                        }
                    }
                }
                Text("Inspect \(clock(selected))").font(.subheadline.monospacedDigit()).accessibilityIdentifier("automation.timelineClock")
                Slider(value: $position, in: 0...1).accessibilityLabel("Inspect night timeline")
                    .accessibilityValue(clock(selected)).accessibilityIdentifier("automation.timelineSlider")
                Text("Blue/red: scheduled cooling/warming · violet: manual hold · green: active rule · amber: dry run. Diamonds mark recorded firings; crosses mark recorded dry runs. Inspecting never changes the bed.").font(.caption).foregroundStyle(Theme.text2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func scheduleLane(_ side: Side) -> some View {
        Chart {
            ForEach(timeline.blocks(for: side)) { block in
                RectangleMark(xStart: .value("From", block.start), xEnd: .value("Until", block.end), yStart: .value("Lower", 0.1), yEnd: .value("Upper", 0.9))
                    .foregroundStyle(block.temperature.map { $0 < 80 ? Theme.cool : $0 > 80 ? Theme.warm : Theme.neutral } ?? Theme.text3)
            }
            if let hold = (side == .left ? snapshot?.sides.left : snapshot?.sides.right)?.hold {
                let start = max(timeline.range.lowerBound, Date(timeIntervalSince1970: hold.startedAt / 1000))
                let end = min(timeline.range.upperBound, Date(timeIntervalSince1970: hold.expiresAt / 1000))
                if end > start {
                    RectangleMark(xStart: .value("From", start), xEnd: .value("Until", end), yStart: .value("Lower", 0.25), yEnd: .value("Upper", 0.75)).foregroundStyle(Theme.violet)
                }
            }
            RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text1)
        }.chartXScale(domain: timeline.range).chartYScale(domain: 0...1).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 32)
            .accessibilityLabel("\(settings.sideName(for: side)) scheduled temperature")
            .accessibilityValue(scheduleLabel(timeline.schedule.state(for: side, at: selected)))
    }
    private func ruleLane(_ lane: AutomationTimeline.RuleLane, side: Side) -> some View {
        Chart {
            ForEach(Array(lane.windows.enumerated()), id: \.offset) { _, window in
                RectangleMark(xStart: .value("From", window.start), xEnd: .value("Until", window.end), yStart: .value("Lower", 0.2), yEnd: .value("Upper", 0.8))
                    .foregroundStyle((lane.rule.definition.dryRun ? Theme.amber : Theme.green).opacity(enabled == true ? 0.5 : 0.2))
            }
            ForEach(Array(firings(lane.id, side: side).enumerated()), id: \.offset) { _, entry in
                PointMark(x: .value("Recorded at", Date(timeIntervalSince1970: entry.start / 1000)), y: .value("Event", 0.5))
                    .symbol(entry.outcome == "dry_run" ? .cross : .diamond).foregroundStyle(entry.outcome == "dry_run" ? Theme.amber : Theme.green)
            }
            RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text1)
        }.chartXScale(domain: timeline.range).chartYScale(domain: 0...1).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 28)
            .accessibilityLabel(lane.rule.definition.name)
            .accessibilityValue(lane.windows.contains { $0.start <= selected && selected < $0.end } ? "Within possible time and day window; other conditions still apply" : "Outside time and day window")
    }
    private func firings(_ ruleID: Int, side: Side) -> [AutomationActivity.Entry] {
        (activity?.nights.flatMap(\.entries) ?? []).filter {
            $0.ruleId == ruleID && ($0.sides.isEmpty || $0.sides.contains(side)) && ["fired", "clamped", "dry_run"].contains($0.outcome)
                && timeline.range.contains(Date(timeIntervalSince1970: $0.start / 1000))
        }
    }
    private func clock(_ date: Date) -> String { AutomationDates.label(date.timeIntervalSince1970 * 1000, timeZone: settings.timeZone) }
    private func scheduleLabel(_ state: TemperatureTimeline.State) -> String {
        if state.powered == false { return "Off" }
        guard state.powered == true else { return "No scheduled power state" }
        guard let temperature = state.temperature else { return "On · target unavailable" }
        return TemperatureConversion.displayTemp(temperature, format: settings.temperatureFormat) + " · On"
    }
}
