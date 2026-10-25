import SwiftUI

struct EpisodePlot: View {
    let detail: EpisodeDetail
    let plot: EpisodeDetail.Plot
    var body: some View {
        if let minimum = plot.minimum, let maximum = plot.maximum {
            let padding = max(1, (maximum - minimum) * 0.2)
            let low = max(0, minimum - padding), high = maximum + padding
            GeometryReader { geometry in
                let scale = geometry.size.width / 400
                let horizontal: (Double) -> Double = { (40 + $0 / detail.durationSeconds * 348) * scale }
                let vertical: (Double) -> Double = { (20 + (high - $0) / (high - low) * 108) * scale }
                ZStack(alignment: .topLeading) {
                    ForEach(0..<3, id: \.self) { index in
                        let value = [high, (high + low) / 2, low][index]
                        Path { path in path.move(to: CGPoint(x: 40 * scale, y: vertical(value))); path.addLine(to: CGPoint(x: 388 * scale, y: vertical(value))) }
                            .stroke(SleepTheme.secondary.opacity(0.12), lineWidth: 1)
                        Text(String(Int(value.rounded()))).font(.system(size: 10 * scale)).foregroundStyle(SleepTheme.secondary)
                            .position(x: 12 * scale, y: vertical(value))
                    }
                    ForEach(plot.segments.indices, id: \.self) { index in
                        let segment = plot.segments[index]
                        if segment.count == 1, let point = segment.first {
                            Circle().fill(SleepTheme.accent).frame(width: 5 * scale, height: 5 * scale)
                                .position(x: horizontal(point.seconds), y: vertical(point.value))
                        } else {
                            Path { path in
                                for (position, point) in segment.enumerated() {
                                    let location = CGPoint(x: horizontal(point.seconds), y: vertical(point.value))
                                    if position == 0 { path.move(to: location) } else { path.addLine(to: location) }
                                }
                            }.stroke(SleepTheme.accent, style: StrokeStyle(lineWidth: 2 * scale, lineJoin: .round))
                        }
                    }
                    HStack { Text(detail.clock(0)); Spacer(); Text(detail.clock(detail.durationSeconds)) }
                        .font(.system(size: 10 * scale)).foregroundStyle(SleepTheme.secondary)
                        .padding(.leading, 40 * scale).padding(.trailing, 12 * scale).offset(y: 141 * scale)
                }
            }.aspectRatio(400.0 / 160.0, contentMode: .fit)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(plot.title): \(plot.count) eligible readings, range \(EpisodeDetail.number(minimum)) to \(EpisodeDetail.number(maximum)) \(plot.unit). Gaps remain unconnected.")
        } else { Text("No eligible readings for this metric.").foregroundStyle(SleepTheme.secondary) }
    }
}
