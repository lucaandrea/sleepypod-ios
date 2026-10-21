import SwiftUI

/// The stagings of one night that can be laid over the Watch on the Stage models screen, and the figures the
/// leaderboard, the model cards and the eligibility checklist show for them. Pure so the tests can drive it.
enum StageLaneSource: Hashable, Identifiable, Sendable {
    case rules
    case challenger
    case pod
    case personal(StageModelKind)

    var id: String {
        switch self {
        case .rules: "rules"
        case .challenger: "challenger"
        case .pod: "pod"
        case .personal(let kind): "personal-\(kind.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .rules: "Rules"
        case .challenger: "Challenger"
        case .pod: "Pod model"
        case .personal(let kind): kind.title
        }
    }

    /// Neutral SF Symbol for the model's tile, as the design's monograms stand in for.
    var symbol: String {
        switch self {
        case .rules: "ruler"
        case .challenger: "flask"
        case .pod: "tree"
        case .personal: "person"
        }
    }

    var origin: String {
        switch self {
        case .rules: "Pod rules"
        case .challenger: "Research model"
        case .pod: "Trained on a Mac"
        case .personal: "This iPhone"
        }
    }

    /// The app's stage-source setting this lane corresponds to.
    var storeSource: StageModelStore.Source {
        switch self {
        case .rules, .challenger: .rules
        case .pod: .pod
        case .personal(let kind): .forKind(kind)
        }
    }
}

/// One source's row on the leaderboard and lane in the chart.
struct StageLane: Identifiable, Equatable {
    let source: StageLaneSource
    /// The name as shown, so the pod's lane can carry the stored model's title ("Pod forest").
    let title: String
    let blocks: [StageComparison.Block]
    let score: StageScore?
    /// Why the lane is empty, when it is.
    let placeholder: String?

    var id: StageLaneSource { source }

    /// Epochs the lane got right, from the score's accuracy over its scored epochs.
    var matched: Int { score.map { Int(($0.accuracy * Double($0.epochs)).rounded()) } ?? 0 }
}

enum StageLanes {
    /// Every source the night has a staging for, with the Watch left out: it is the band every lane sits in.
    static func lanes(_ comparison: StageComparison, podTitle: String?, challengerBundled: Bool) -> [StageLane] {
        var lanes = [StageLane(source: .rules, title: "Rules", blocks: comparison.pod, score: comparison.podScore,
                               placeholder: comparison.podError != nil ? "Pod stages unavailable" : comparison.pod.isEmpty ? "No pod stages this night" : nil)]
        if challengerBundled || comparison.modelStatus != .notBundled {
            let placeholder: String? = switch comparison.modelStatus {
            case .notBundled: "Model not bundled"
            case .failed(let message): "Model unavailable: \(message)"
            case .ready: comparison.model.isEmpty ? "No pod heart rate this night" : nil
            }
            lanes.append(StageLane(source: .challenger, title: "Challenger", blocks: comparison.model, score: comparison.modelScore, placeholder: placeholder))
        }
        if let pod = comparison.podModel {
            lanes.append(StageLane(source: .pod, title: podTitle ?? "Pod model", blocks: pod.blocks, score: pod.score,
                                   placeholder: pod.error.map { "Model unavailable: \($0)" } ?? (pod.blocks.isEmpty ? "No pod heart rate this night" : nil)))
        }
        for kind in StageModelKind.allCases {
            if let personal = comparison.personal[kind] {
                lanes.append(StageLane(source: .personal(kind), title: kind.title, blocks: personal.blocks, score: personal.score,
                                       placeholder: personal.error.map { "Model unavailable: \($0)" } ?? (personal.blocks.isEmpty ? "No pod heart rate this night" : nil)))
            }
        }
        return lanes
    }

    /// Lanes by κ, best first; unscored lanes keep their order at the end.
    static func ranked(_ lanes: [StageLane]) -> [StageLane] {
        lanes.enumerated().sorted { lhs, rhs in
            switch (lhs.element.score?.kappa, rhs.element.score?.kappa) {
            case let (l?, r?): l != r ? l > r : lhs.offset < rhs.offset
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The lane to open on: the one the app stages with when it is on the board, otherwise the best scored.
    static func initialSelection(_ lanes: [StageLane], appSource: StageModelStore.Source) -> StageLaneSource? {
        if appSource != .rules, let active = lanes.first(where: { $0.source.storeSource == appSource }) { return active.source }
        return ranked(lanes).first?.source
    }

    /// Hour ticks across a bed window, at most `maximum` of them, on whole hours.
    static func hourTicks(start: Date, end: Date, maximum: Int = 6, calendar: Calendar = .current) -> [Date] {
        let hours = max(1, Int((end.timeIntervalSince(start) / 3600).rounded(.up)))
        let step = max(1, Int((Double(hours) / Double(maximum)).rounded(.up)))
        guard var tick = calendar.dateInterval(of: .hour, for: start)?.end else { return [] }
        var ticks: [Date] = []
        while tick < end {
            ticks.append(tick)
            tick = tick.addingTimeInterval(Double(step) * 3600)
        }
        return ticks
    }

    /// The leave-one-night-out diagram: `rows` runs over `nights`, each scoring one night (first, middle, last).
    static func lonoRows(nights: Int, rows: Int = 3) -> [[Bool]] {
        let count = max(nights, 2)
        let scored = rows == 1 ? [0] : (0..<rows).map { index in index * (count - 1) / max(rows - 1, 1) }
        return scored.map { held in (0..<count).map { $0 == held } }
    }

    struct CheckItem: Equatable, Identifiable {
        let label: String
        let value: String
        let passed: Bool
        var id: String { label }
    }

    /// The eligibility bar as three testable conditions, phrased the way `StageModelStore.isEligible` decides.
    @MainActor
    static func checklist(_ card: StageChallenger.Card) -> [CheckItem] {
        let margin = StageModelStore.kappaMargin
        let lono = card.metrics?.lono
        let kappa = lono?.kappa
        let nights = lono?.nights ?? 0
        func text(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }
        let rules = card.metrics?.rules?.kappa
        let challenger = card.metrics?.challenger?.kappa
        let won = card.metrics?.nightsWon ?? 0
        return [
            CheckItem(label: "κ at least \(text(margin)) above the rules", value: "\(text(kappa)) vs \(text(rules))",
                      passed: kappa.map { k in rules.map { k >= $0 + margin } ?? false } ?? false),
            CheckItem(label: "κ at least \(text(margin)) above the challenger", value: "\(text(kappa)) vs \(text(challenger))",
                      passed: kappa.map { k in challenger.map { k >= $0 + margin } ?? true } ?? false),
            CheckItem(label: "Won most of at least \(StageModelStore.minimumNights) nights", value: "\(won) of \(nights)",
                      passed: nights >= StageModelStore.minimumNights && won * 2 > nights)
        ]
    }
}

// MARK: - Views

/// The neutral icon tile the design puts beside every model.
struct ModelTile: View {
    let symbol: String
    var size: CGFloat = 32
    var inverted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(inverted ? Theme.background : Theme.text1)
            .frame(width: size, height: size)
            .background(inverted ? Theme.text1 : Theme.active, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small mono status pill ("IN USE", "LEARNING").
struct StatusPill: View {
    let text: String
    var color = Theme.green

    var body: some View {
        Text(text).font(.mono(10, relativeTo: .caption2)).tracking(0.5).foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 20)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Capsule button in the design's three weights: filled, tinted, plain.
struct CapsuleButtonStyle: ButtonStyle {
    enum Weight { case filled, tinted, plain }
    var weight: Weight = .tinted
    var color: Color = Theme.text1
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(weight == .filled ? Theme.background : color)
            .padding(.horizontal, weight == .plain ? 12 : 16).frame(height: 40)
            .background {
                switch weight {
                case .filled: Capsule().fill(color)
                case .tinted: Capsule().fill(Theme.active)
                case .plain: Color.clear
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// Chips and other short items laid out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return place(subviews: subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = place(subviews: subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, layout.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func place(subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// Apple-style stage lanes: one lane per stage with a dashed guide, the reference drawn as a pale band and the
/// staging under review as solid bars, joined by hairline connectors where the stage changes.
struct StageLaneChart: View {
    let start: Date
    let end: Date
    let band: [StageComparison.Block]
    let bars: [StageComparison.Block]
    var placeholder: String?
    var selection: Date?
    var onSelect: ((Date?) -> Void)?

    private let order: [SleepAnalyzer.SleepStage] = [.wake, .rem, .light, .deep]
    private let labelWidth: CGFloat = 40
    private let laneHeight: CGFloat = 28

    private var span: TimeInterval { max(1, end.timeIntervalSince(start)) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(order, id: \.self) { stage in
                        Text(stage.label).font(.mono(10, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .trailing).frame(height: laneHeight)
                    }
                }
                .frame(width: labelWidth)
                GeometryReader { proxy in
                    Canvas { context, size in
                        draw(in: &context, size: size)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in onSelect?(date(atX: value.location.x, width: proxy.size.width)) }
                        .onEnded { _ in onSelect?(nil) })
                }
                .frame(height: laneHeight * 4)
                .overlay {
                    if let placeholder {
                        Text(placeholder).font(.footnote).foregroundStyle(Theme.text2)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.card, in: Capsule())
                    }
                }
            }
            hourAxis
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeholder ?? summary)
    }

    private func date(atX x: CGFloat, width: CGFloat) -> Date? {
        guard width > 0 else { return nil }
        let fraction = min(max(x / width, 0), 1)
        return start.addingTimeInterval(fraction * span)
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat { width * date.timeIntervalSince(start) / span }

    private func laneY(_ stage: SleepAnalyzer.SleepStage) -> CGFloat {
        CGFloat(order.firstIndex(of: stage) ?? 0) * laneHeight + laneHeight / 2
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let guide = Theme.border1
        for stage in order {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: laneY(stage)))
            path.addLine(to: CGPoint(x: size.width, y: laneY(stage)))
            context.stroke(path, with: .color(guide), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        for block in band {
            let x0 = x(block.start, width: size.width), x1 = x(block.end, width: size.width)
            let rect = CGRect(x: x0, y: laneY(block.stage) - 10, width: max(1, x1 - x0), height: 20)
            context.fill(Path(rect), with: .color(block.stage.displayColor.opacity(0.18)))
        }
        var previous: StageComparison.Block?
        for block in bars {
            if let previous, previous.stage != block.stage, block.start.timeIntervalSince(previous.end) <= 1 {
                let x0 = x(block.start, width: size.width)
                var path = Path()
                path.move(to: CGPoint(x: x0, y: laneY(previous.stage)))
                path.addLine(to: CGPoint(x: x0, y: laneY(block.stage)))
                context.stroke(path, with: .color(Theme.border2), lineWidth: 1)
            }
            previous = block
        }
        for block in bars {
            let x0 = x(block.start, width: size.width), x1 = x(block.end, width: size.width)
            let rect = CGRect(x: x0, y: laneY(block.stage) - 6, width: max(2, x1 - x0), height: 12)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(block.stage.displayColor))
        }
        if let selection {
            let sx = x(selection, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: sx, y: 0))
            path.addLine(to: CGPoint(x: sx, y: size.height))
            context.stroke(path, with: .color(Theme.text3), lineWidth: 1)
        }
    }

    private var hourAxis: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - labelWidth - 8
            ForEach(StageLanes.hourTicks(start: start, end: end), id: \.self) { tick in
                Text(DisplayTime.tick(minutes: Calendar.current.component(.hour, from: tick) * 60 + Calendar.current.component(.minute, from: tick)))
                    .font(.mono(10, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                    .fixedSize()
                    .position(x: labelWidth + 8 + x(tick, width: width), y: 7)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private var summary: String {
        order.map { stage in
            let seconds = bars.filter { $0.stage == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            return "\(stage.label) \(DisplayTime.duration(Int(seconds)))"
        }.joined(separator: ", ")
    }
}
