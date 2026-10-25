import SwiftUI

extension SleepAnalyzer.SleepStage {
    var displayColor: Color {
        switch self {
        case .wake: Theme.warm
        case .rem: Theme.violet
        case .light: Theme.cool
        case .deep: Theme.indigo
        }
    }
    var label: String { self == .wake ? "Awake" : rawValue }
}

struct SleepStagesTimelineView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let stages: [SleepAnalyzer.SleepEpoch]
    let qualityScore: Int?
    private let order: [SleepAnalyzer.SleepStage] = [.wake, .rem, .light, .deep]

    struct Segment {
        let stage: SleepAnalyzer.SleepStage
        let start: Date
        var end: Date
    }

    /// Consecutive epochs of one stage merge into a single block; short gaps between blocks are
    /// closed so the hypnogram reads as continuous lanes rather than per-epoch hairlines.
    static func segments(_ epochs: [SleepAnalyzer.SleepEpoch], maxGap: TimeInterval = 300) -> [Segment] {
        var result: [Segment] = []
        for epoch in epochs.sorted(by: { $0.start < $1.start }) {
            let end = epoch.start.addingTimeInterval(max(epoch.duration, 1))
            if var last = result.last, epoch.start.timeIntervalSince(last.end) <= maxGap {
                if last.stage == epoch.stage {
                    last.end = max(last.end, end)
                    result[result.count - 1] = last
                    continue
                }
                last.end = epoch.start
                result[result.count - 1] = last
            }
            result.append(Segment(stage: epoch.stage, start: epoch.start, end: end))
        }
        return result
    }

    /// Where the stages came from; the model badge marks a night staged by a trained Core ML model.
    var source: SleepAnalyzer.StageSource = .rules
    var modelName: String?
    var sourceLabel: String?
    var gapTolerance: TimeInterval = 300
    var showDurations = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("STAGES")
                Spacer()
                if source == .model { StageSourceBadge(.model(modelName ?? "model")) }
            }
            if let sourceLabel { Text(sourceLabel).font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
            if stages.isEmpty {
                Text("Not enough data for stage analysis").font(.subheadline).foregroundStyle(Theme.text2)
            } else {
                let segments = Self.segments(stages, maxGap: gapTolerance)
                let start = segments.first?.start ?? Date()
                let total = max(1, (segments.map(\.end).max() ?? start).timeIntervalSince(start))
                Canvas { context, size in
                    for segment in segments {
                        guard let lane = order.firstIndex(of: segment.stage) else { continue }
                        let x = size.width * segment.start.timeIntervalSince(start) / total
                        let width = max(2, size.width * segment.end.timeIntervalSince(segment.start) / total)
                        let rect = CGRect(x: x, y: CGFloat(lane) * 23 + 2, width: width, height: 14)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(segment.stage.displayColor))
                    }
                }
                .frame(height: 88)
                .accessibilityElement()
                .accessibilityLabel(accessibilitySummary(segments))
                legend
            }
        }
        .cardStyle()
    }

    private var legend: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            ForEach(order, id: \.self) { stage in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(stage.displayColor).frame(width: 7, height: 7)
                        Text(stage.label)
                    }
                    if showDurations {
                        let seconds = stages.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
                        Text(DisplayTime.duration(Int(seconds))).foregroundStyle(Theme.text1).monospacedDigit()
                    }
                }
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
            }
        }
        .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text2)
        .accessibilityHidden(true)
    }

    private func accessibilitySummary(_ segments: [Segment]) -> String {
        order.map { stage in
            let seconds = segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            return "\(stage.label) \(DisplayTime.duration(Int(seconds)))"
        }.joined(separator: ", ")
    }
}
