import Charts
import SwiftUI

struct SystemSchedulerNightCard: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let timeline: SystemSchedulerTimeline
    @State private var selectedNight = 0
    @State private var position = 0.0
    var body: some View {
        let nights = timeline.nights()
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Seven nights").font(.headline)
                Picker("Night", selection: $selectedNight) {
                    ForEach(Array(nights.enumerated()), id: \.offset) { index, night in
                        Text(index == 0 ? "Tonight" : timeline.clock(night.start, includeDay: true)).tag(index)
                    }
                }.accessibilityIdentifier("scheduler.night")
                if nights.indices.contains(selectedNight) {
                    let night = nights[selectedNight]
                    let range = timeline.axis(for: night)
                    let selected = range.lowerBound.addingTimeInterval(position * range.upperBound.timeIntervalSince(range.lowerBound))
                    Text("\(timeline.clock(night.start, includeDay: true)) → \(timeline.clock(night.end, includeDay: true))").font(.footnote).foregroundStyle(Theme.text2)
                    if !timeline.enabled { Text("The scheduler is disabled. These occurrences are shown for reference.").foregroundStyle(Theme.amber) }
                    if night.occurrences.isEmpty { Text("No jobs run this night.").foregroundStyle(Theme.text2) }
                    ForEach(Side.allCases) { side in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(settings.sideName(for: side)).font(.subheadline.weight(.semibold))
                            Text(targetLabel(night, side: side, at: selected)).font(.footnote.monospacedDigit())
                            lane(night, side: side, range: range, selected: selected)
                        }
                    }
                    Text("Inspect \(timeline.clock(selected))").font(.subheadline.monospacedDigit()).accessibilityIdentifier("scheduler.inspectedTime")
                    Slider(value: $position, in: 0...1).accessibilityLabel("Inspect scheduled targets").accessibilityValue(timeline.clock(selected)).accessibilityIdentifier("scheduler.inspect")
                    Text("Blue/red: scheduled targets · green: power on · gray: power off · amber: alarm. Gaps mean no target is reported. The chart is a plan, not measured temperature.").font(.caption).foregroundStyle(Theme.text2)
                    DisclosureGroup("All occurrences this night · \(night.occurrences.count)") {
                        Text("Pod maintenance outside the evening chart is included below.").font(.caption).foregroundStyle(Theme.text2)
                        ForEach(night.occurrences, id: \.identity) { occurrence in
                            SystemSchedulerOccurrenceRow(occurrence: occurrence, timeline: timeline)
                            Divider()
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func targetLabel(_ night: SystemSchedulerTimeline.Night, side: Side, at selected: Date) -> String {
        guard let target = SystemSchedulerTimeline.heldTarget(night.occurrences, side: side, at: selected) else { return "No scheduled target at this time" }
        return "Scheduled · " + TemperatureConversion.displayTemp(Int(target.rounded()), format: settings.temperatureFormat)
    }
    private func lane(_ night: SystemSchedulerTimeline.Night, side: Side, range: ClosedRange<Date>, selected: Date) -> some View {
        let spans = SystemSchedulerTimeline.targetSpans(night, side: side, range: range)
        let events = night.occurrences.filter { $0.side == side && range.contains($0.date) && ["power_on", "power_off", "alarm"].contains($0.type) }
        let ticks = [range.lowerBound, range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2), range.upperBound]
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(spans) { span in
                    RuleMark(xStart: .value("From", span.start), xEnd: .value("Until", span.end), y: .value("Target °F", span.temperature))
                        .lineStyle(StrokeStyle(lineWidth: 4)).foregroundStyle(TempColor.forScheduled(Int(span.temperature.rounded())))
                }
                ForEach(events, id: \.identity) { event in
                    PointMark(x: .value("Time", event.date), y: .value("Event", 52))
                        .symbol(event.type == "alarm" ? .diamond : .circle)
                        .foregroundStyle(event.type == "alarm" ? Theme.amber : event.type == "power_on" ? Theme.green : Theme.text3)
                }
                RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text1.opacity(0.7))
            }.chartXScale(domain: range).chartYScale(domain: 48...112)
            .chartXAxis { AxisMarks(values: ticks) { _ in
                AxisGridLine()
            } }.chartYAxis { AxisMarks(values: [60, 80, 100]) { value in
                AxisGridLine(); AxisValueLabel { if let value = value.as(Int.self) { Text(TemperatureConversion.valueText(value, format: settings.temperatureFormat)) } }
            } }.frame(height: dynamicTypeSize.isAccessibilitySize ? 210 : 150)
            .accessibilityLabel("\(settings.sideName(for: side)) scheduled targets and events")
            .accessibilityValue(targetLabel(night, side: side, at: selected))
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(timeline.clock(range.lowerBound)).fixedSize()
                    Spacer(minLength: 16)
                    Text(timeline.clock(range.upperBound)).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("From \(timeline.clock(range.lowerBound))")
                    Text("Until \(timeline.clock(range.upperBound))")
                }
            }.font(.caption).foregroundStyle(Theme.text2)
        }
    }
}
