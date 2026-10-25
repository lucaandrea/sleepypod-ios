import SwiftUI

struct EpisodeDetailContent: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    let detail: EpisodeDetail
    @State private var metric = "heartRate"
    @State private var readings = false
    private var plot: EpisodeDetail.Plot? { detail.plots.first { $0.key == metric } ?? detail.plots.first }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 16) {
            statistic("Bed presence", SleepAnalytics.duration(detail.episode.occupiedMinutes))
            statistic("Episode window", SleepAnalytics.duration(detail.episode.windowMinutes))
            statistic("Recorded exits", String(detail.episode.exits))
            statistic("Recorded readings", String(detail.samples.count))
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Recorded presence").sleepText(.small)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(SleepTheme.border(scheme))
                    ForEach(detail.intervals.indices, id: \.self) { index in
                        let interval = detail.intervals[index]
                        Rectangle().fill(SleepTheme.accent)
                            .frame(width: max(0, (interval.end - interval.start) / detail.durationSeconds * geometry.size.width))
                            .offset(x: interval.start / detail.durationSeconds * geometry.size.width)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 4))
            }.frame(height: 14).accessibilityElement(children: .ignore)
                .accessibilityLabel(detail.presenceKnown ? detail.intervals.map { "\(detail.clock($0.start)) to \(detail.clock($0.end))" }.joined(separator: "; ") : "Presence intervals are unavailable.")
            HStack { Text(detail.clock(0)); Spacer(); Text(detail.clock(detail.durationSeconds)) }
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            if !detail.presenceKnown { Text("Presence intervals are unavailable. Vitals remain in the recorded readings below.").foregroundStyle(SleepTheme.secondary) }
        }
        SleepSegmentedPicker(title: "Vital metric", options: ["heartRate", "hrv", "respiratoryRate"], selection: $metric) {
            $0 == "heartRate" ? "Heart rate" : $0 == "hrv" ? "HRV" : "Breathing"
        }
        if let plot {
            VStack(alignment: .leading, spacing: 6) {
                Text(plot.title).sleepText(.cardTitle)
                HStack(alignment: .firstTextBaseline) { Text(EpisodeDetail.number(plot.average)).sleepText(.metric); Text(plot.unit).foregroundStyle(SleepTheme.secondary) }
                Text("\(plot.count) eligible readings · \(EpisodeDetail.number(plot.minimum))–\(EpisodeDetail.number(plot.maximum)) \(plot.unit)")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
            EpisodePlot(detail: detail, plot: plot)
        }
        ForEach(Array(detail.notes.prefix(2)), id: \.self) { Text($0).sleepText(.caption).foregroundStyle(SleepTheme.secondary) }
        Button(readings ? "Hide recorded readings" : "Show recorded readings") { readings.toggle() }.buttonStyle(SleepButtonStyle(fill: true))
        if readings { EpisodeReadings(detail: detail) }
    }
    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).sleepText(.caption).foregroundStyle(SleepTheme.secondary); Text(value).sleepText(.cardTitle) }
    }
}
