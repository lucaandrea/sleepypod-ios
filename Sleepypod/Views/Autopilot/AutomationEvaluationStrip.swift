import Charts
import SwiftUI

struct AutomationEvaluationStrip: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let strip: AutomationEvaluationStripData
    let timeZone: String
    @State private var selected: Date?
    @State private var inspection = false
    private func date(_ index: Int) -> Date { Date(timeIntervalSince1970: (strip.startMs + Double(index) * 60_000) / 1000) }
    private var selectedIndex: Int {
        guard let selected else { return 179 }
        return min(179, max(0, Int(floor((selected.timeIntervalSince1970 * 1000 - strip.startMs) / 60_000))))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 3 hours").font(.subheadline)
            Chart {
                ForEach(Array(strip.cooldowns.enumerated()), id: \.offset) { _, span in
                    RectangleMark(xStart: .value("Start", date(span[0])), xEnd: .value("End", date(span[1] + 1)), yStart: .value("Low", 0), yEnd: .value("High", 1))
                        .foregroundStyle(Theme.text3.opacity(0.3)).accessibilityLabel("Cooldown")
                }
                ForEach(strip.ticks.indices, id: \.self) { index in
                    let kind = strip.ticks[index]
                    if kind != .none && kind != .cooldown {
                        RectangleMark(xStart: .value("Minute", date(index)), xEnd: .value("End", date(index).addingTimeInterval(36)), yStart: .value("Low", 0), yEnd: .value("High", 1))
                            .foregroundStyle(kind.color.opacity(kind == .missing ? 0.45 : 1))
                            .accessibilityLabel(kind.label)
                    }
                }
                if selected != nil {
                    RuleMark(x: .value("Selected minute", date(selectedIndex))).foregroundStyle(Theme.text1)
                }
            }
            .chartXScale(domain: date(0)...date(180)).chartYScale(domain: 0...1)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: [date(0), date(180)]) { _ in AxisValueLabel(format: .dateTime.hour().minute()) }
            }
            .chartXSelection(value: $selected).frame(height: 64)
            .accessibilityLabel("Three-hour evaluation strip. Use Inspect minute to read each interval.")
            .environment(\.timeZone, TimeZone(identifier: timeZone) ?? .current)
            if let latest = strip.ticks.lastIndex(where: { $0 == .fired || $0 == .would }) {
                Text("Latest \(strip.ticks[latest].label.lowercased()) · \(clock(latest))").font(.caption)
            }
            Text("Green fired · amber would fire · gray skipped or cooldown · red error or missing evaluation")
                .font(.caption).foregroundStyle(Theme.text2)
            DisclosureGroup("Inspect minute", isExpanded: $inspection) {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(clock(selectedIndex)) · \(strip.ticks[selectedIndex].label)")
                            .font(.footnote).fixedSize(horizontal: false, vertical: true)
                        minuteStepper.labelsHidden()
                    }
                } else { minuteStepper }
            }.font(.footnote)
            if selected != nil, !inspection { Text("\(clock(selectedIndex)) · \(strip.ticks[selectedIndex].label)").font(.caption) }
        }
    }
    private var minuteStepper: some View {
        Stepper(value: Binding(get: { selectedIndex }, set: { selected = date($0) }), in: 0...179) {
            Text("\(clock(selectedIndex)) · \(strip.ticks[selectedIndex].label)").font(.footnote)
        }.accessibilityIdentifier("diagnostics.minute")
    }
    private func clock(_ index: Int) -> String { AutomationDates.label(date(index).timeIntervalSince1970 * 1000, timeZone: timeZone) }
}
