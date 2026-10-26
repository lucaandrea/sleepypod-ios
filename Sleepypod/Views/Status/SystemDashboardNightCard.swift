import Charts
import SwiftUI

struct SystemDashboardNightCard: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    let night: DashboardNight
    let history: SystemThermalHistory?
    let sides: [Side]
    @State private var position = 0.0
    private var selected: Date { night.start.addingTimeInterval(position * night.end.timeIntervalSince(night.start)) }
    private var celsius: Bool { settings.temperatureFormat == .celsius }
    private var chart: ThermalChartData? {
        history.map { .init(from: $0.from, to: $0.to, gap: $0.bucketSec * 3000, points: $0.points, powerOn: $0.powerOn, available: $0.available, bedTargetSince: $0.bedTargetSince) }
    }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tonight").font(.headline).accessibilityIdentifier("dashboard.tonightTitle")
                Text("\(night.timeline.clock(night.start, includeDay: true)) → \(night.timeline.clock(night.end)) · \(night.timeline.timezone)").font(.footnote).foregroundStyle(Theme.text2)
                if !night.timeline.validTimezone { Text("Pod timezone is unavailable; times are shown in UTC.").foregroundStyle(Theme.amber) }
                if !night.timeline.enabled { Text("Scheduler is off. This is the saved plan.").foregroundStyle(Theme.amber) }
                if let next = night.nextTemperature(sides: sides), let side = next.side {
                    Text("Next: \(settings.sideName(for: side)) → \(temperature(next.targetTempF)) at \(night.timeline.clock(next.date))").font(.subheadline)
                } else { Text("No upcoming temperature changes are reported.").font(.footnote).foregroundStyle(Theme.text2) }
                ForEach(sides) { side in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.sideName(for: side)).font(.subheadline.weight(.semibold))
                        Text("Target \(temperature(night.target(side: side, at: selected))) · Bed \(temperature(recorded(side)))").font(.footnote.monospacedDigit())
                        lane(side)
                    }
                }
                if !night.podEvents.isEmpty {
                    Text("Pod").font(.subheadline.weight(.semibold))
                    Chart {
                        ForEach(night.podEvents, id: \.identity) { event in
                            PointMark(x: .value("Time", event.date), y: .value("Pod", 0)).symbol(.diamond).foregroundStyle(Theme.amber)
                        }
                        RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text2)
                    }.chartXScale(domain: night.range).chartYScale(domain: -1...1).chartYAxis(.hidden).chartXAxis(.hidden).frame(height: 36)
                    DisclosureGroup("Pod events · \(night.podEvents.count)") {
                        ForEach(night.podEvents, id: \.identity) { event in
                            SystemSchedulerOccurrenceRow(occurrence: event, timeline: night.timeline)
                        }
                    }
                }
                Text("Inspect \(night.timeline.clock(selected))").font(.subheadline.monospacedDigit()).accessibilityIdentifier("dashboard.inspectedTime")
                Slider(value: $position, in: 0...1).accessibilityLabel("Inspect tonight").accessibilityValue(night.timeline.clock(selected)).accessibilityIdentifier("dashboard.inspect")
                Text("Dashed: planned target · Solid: measured bed · Green: power on · Gray: power off · Amber: alarm. Gaps mean no reading. Inspection does not change the bed.").font(.caption).foregroundStyle(Theme.text2)
                NavigationLink("Open scheduler") { SystemSchedulerScreen() }.accessibilityIdentifier("dashboard.scheduler")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func recorded(_ side: Side) -> Double? {
        chart?.nearest(at: selected.timeIntervalSince1970 * 1000)?.values[side == .left ? .leftBed : .rightBed]
    }
    private func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return display(value).formatted(.number.precision(.fractionLength(0...1))) + (celsius ? "°C" : "°F")
    }
    private func display(_ value: Double) -> Double { celsius ? (value - 32) * 5 / 9 : value }
    private func lane(_ side: Side) -> some View {
        let signal: ThermalSignal = side == .left ? .leftBed : .rightBed
        let samples = chart?.samples(.bedTarget, celsius: celsius).filter { $0.signal == signal && night.range.contains(Date(timeIntervalSince1970: $0.time / 1000)) } ?? []
        let events = night.events.filter { $0.side == side && ["power_on", "power_off", "alarm"].contains($0.type) }
        return Chart {
            ForEach(night.spans(side: side)) { span in
                RuleMark(xStart: .value("From", span.start), xEnd: .value("Until", span.end), y: .value("Planned target", display(span.temperature)))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3])).foregroundStyle(Theme.text2)
            }
            ForEach(samples) { sample in
                LineMark(x: .value("Time", Date(timeIntervalSince1970: sample.time / 1000)), y: .value("Measured bed", sample.value), series: .value("Recorded segment", sample.segment))
                    .foregroundStyle(side == .left ? Theme.cool : Theme.purple)
            }
            ForEach(events, id: \.identity) { event in
                PointMark(x: .value("Time", event.date), y: .value("Event", display(52)))
                    .symbol(event.type == "alarm" ? .diamond : .circle)
                    .foregroundStyle(event.type == "alarm" ? Theme.amber : event.type == "power_on" ? Theme.green : Theme.text3)
            }
            RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text1.opacity(0.6))
        }.chartXScale(domain: night.range).chartYScale(domain: display(50)...display(112))
            .chartXAxis { AxisMarks(values: [night.start, night.end]) { value in
                AxisGridLine()
                AxisValueLabel { if let date = value.as(Date.self) { Text(night.timeline.clock(date)) } }
            } }.frame(height: typeSize.isAccessibilitySize ? 220 : 140)
            .accessibilityLabel("\(settings.sideName(for: side)) tonight: scheduled target and measured bed")
    }
}
