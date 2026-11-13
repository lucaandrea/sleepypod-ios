import Charts
import SwiftUI

struct MorningBriefContent: View {
    let report: PersonalSleepReport
    var compact = false
    @Environment(\.dynamicTypeSize) private var textSize
    private var brief: MorningBrief { .init(report: report) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Evidence saved \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline).foregroundStyle(Theme.text2)
            Text("This brief describes that report’s evidence. It is not a new analysis of last night.")
                .font(.caption).foregroundStyle(Theme.text2)
            ForEach(brief.takeaways) { takeaway in
                VStack(alignment: .leading, spacing: 7) {
                    Text(takeaway.title).font(.headline)
                    Text(takeaway.badge).font(.caption.weight(.semibold)).foregroundStyle(Theme.reportAccent)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Theme.reportAccent.opacity(0.09), in: Capsule())
                    Text(takeaway.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                    .accessibilityIdentifier("brief.takeaway.\(takeaway.id)")
            }
            if brief.takeaways.isEmpty {
                Text("This saved report has no calculated highlights. Open its full interpretation and evidence below.").font(.subheadline)
            }
            if let comparison = brief.comparison { comparisonView(comparison) }
            else if !compact {
                Text("This report has no usable saved chart data. Its original evidence is still available below; a new chart has not been reconstructed from prose.")
                    .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("brief.noChart")
            }
        }
    }

    private func comparisonView(_ comparison: ReportSleepComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recorded sleep · hours").font(.headline)
            Text(comparison.sourceName).font(.subheadline).foregroundStyle(Theme.text2)
            if comparison.observedCount > 0 {
                Chart(Array(comparison.days.enumerated()), id: \.element.id) { index, day in
                    if let minutes = day.minutes {
                        BarMark(x: .value("Sleep day", index), y: .value("Recorded hours", minutes / 60))
                            .foregroundStyle(Theme.reportAccent)
                            .accessibilityLabel(comparison.dateLabel(day.end))
                            .accessibilityValue(ReportSleepComparison.duration(minutes) + " recorded")
                    }
                }
                .chartXScale(domain: -0.5...13.5)
                .chartYScale(domain: 0...max(10, ceil((comparison.days.compactMap(\.minutes).max() ?? 0) / 60)))
                .chartXAxis {
                    if !textSize.isAccessibilitySize {
                        AxisMarks(values: [0, 6, 13]) { value in
                            if let index = value.as(Int.self), comparison.days.indices.contains(index) {
                                // Edge labels grow into the plot instead of beyond its clipped bounds.
                                AxisValueLabel(anchor: index == 0 ? .topLeading : index == 13 ? .topTrailing : .top) {
                                    Text(comparison.dateLabel(comparison.days[index].end)).fixedSize()
                                }
                            }
                        }
                    }
                }
                .frame(height: textSize.isAccessibilitySize ? 210 : compact ? 125 : 170)
                .accessibilityIdentifier("brief.chart")
                if textSize.isAccessibilitySize, let first = comparison.days.first, let last = comparison.days.last {
                    Text("From \(comparison.dateLabel(first.end)) to \(comparison.dateLabel(last.end))")
                        .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("brief.chart.dates")
                }
            } else {
                Text("No observations in this saved window.").font(.subheadline).accessibilityIdentifier("brief.chart.empty")
            }
            Text("Blank days are unknown, not zero. Sleep days run noon to noon in \(comparison.timeZone). Naps and partial recordings can be included.")
                .font(.caption).foregroundStyle(Theme.text2)
            if !compact {
                Text("Health imported \(comparison.importedAt.formatted(date: .abbreviated, time: .shortened)). The chart was frozen when this report was requested.")
                    .font(.caption).foregroundStyle(Theme.text2)
                if comparison.omittedRecords > 0 {
                    Text("\(comparison.omittedRecords) invalid or ambiguous records were excluded from this comparison.").font(.caption).foregroundStyle(Theme.text2)
                }
                DisclosureGroup("Read each recorded day") {
                    ForEach(comparison.days) { day in
                        LabeledContent(comparison.dateLabel(day.end), value: day.minutes.map(ReportSleepComparison.duration) ?? "Unknown")
                            .font(.subheadline).padding(.vertical, 4)
                    }
                }.accessibilityIdentifier("brief.days")
            }
        }
    }
}
