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
            Text("Recorded presence").font(.subheadline)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.border1)
                    ForEach(detail.intervals.indices, id: \.self) { index in
                        let interval = detail.intervals[index]
                        Rectangle().fill(Theme.text1)
                            .frame(width: max(0, (interval.end - interval.start) / detail.durationSeconds * geometry.size.width))
                            .offset(x: interval.start / detail.durationSeconds * geometry.size.width)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 4))
            }.frame(height: 14).accessibilityElement(children: .ignore)
                .accessibilityLabel(detail.presenceKnown ? detail.intervals.map { "\(detail.clock($0.start)) to \(detail.clock($0.end))" }.joined(separator: "; ") : "Presence intervals are unavailable.")
            HStack { Text(detail.clock(0)); Spacer(); Text(detail.clock(detail.durationSeconds)) }
                .font(.caption).foregroundStyle(Theme.text2)
            if !detail.presenceKnown { Text("Presence intervals are unavailable. Vitals remain in the recorded readings below.").foregroundStyle(Theme.text2) }
        }
        FeatureSegments(title: "Vital metric", options: ["heartRate", "hrv", "respiratoryRate"], selection: $metric) {
            $0 == "heartRate" ? "Heart rate" : $0 == "hrv" ? "HRV" : "Breathing"
        }
        if let plot {
            VStack(alignment: .leading, spacing: 6) {
                Text(plot.title).font(.headline)
                HStack(alignment: .firstTextBaseline) { Text(EpisodeDetail.number(plot.average)).font(.system(.largeTitle, design: .rounded, weight: .light)); Text(plot.unit).foregroundStyle(Theme.text2) }
                Text("\(plot.count) eligible readings · \(EpisodeDetail.number(plot.minimum))–\(EpisodeDetail.number(plot.maximum)) \(plot.unit)")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
            EpisodePlot(detail: detail, plot: plot)
        }
        ForEach(Array(detail.notes.prefix(2)), id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.text2) }
        Button(readings ? "Hide recorded readings" : "Show recorded readings") { readings.toggle() }.buttonStyle(GlassButtonStyle())
        if readings { EpisodeReadings(detail: detail) }
    }
    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(Theme.text2); Text(value).font(.headline) }
    }
}
