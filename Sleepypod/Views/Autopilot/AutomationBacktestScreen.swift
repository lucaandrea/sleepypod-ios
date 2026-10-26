import Charts
import SwiftUI

struct AutomationBacktestScreen: View {
    let definition: AutomationDefinition
    let client: any AutomationClient
    @State private var model: AutomationBacktestWorkspace
    init(definition: AutomationDefinition, client: any AutomationClient) {
        self.definition = definition; self.client = client; _model = State(initialValue: .init(side: definition.side ?? .left, client: client))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(definition.name).font(.title3.bold())
                Text("Replay this draft against recorded signals. This does not save the rule or send bed commands.").font(.footnote).foregroundStyle(Theme.text2)
                Picker("Replay side", selection: $model.side) { Text("Left").tag(Side.left); Text("Right").tag(Side.right) }.pickerStyle(.segmented)
                if model.loading { ProgressView("Loading nights…") }
                if !model.nights.isEmpty {
                    Picker("Night", selection: $model.night) {
                        ForEach(model.nights) { Text($0.label).tag(Optional($0.id)) }
                    }
                } else if !model.loading { Text("No recorded nights for this side.").foregroundStyle(Theme.text2) }
                Button(model.running ? "Replaying…" : "Run backtest") { Task { await model.run(definition) } }
                    .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                    .disabled(model.loading || model.running || definition.validation != nil).accessibilityIdentifier("automation.runBacktest")
                NavigationLink { AutomationZoneReplayScreen(client: client, side: model.side, night: model.night) } label: { Label("Recorded pressure zones", systemImage: "bed.double") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber) }
                if let response = model.result {
                    if !model.isCurrent(definition) { Text("The draft or night changed. Run again to update these results.").foregroundStyle(Theme.amber) }
                    if let message = response.message { Text(message).foregroundStyle(Theme.text2) }
                    if response.ok, let result = response.result {
                        AutomationBacktestCharts(result: result)
                    }
                }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Backtest").navigationBarTitleDisplayMode(.inline)
            .task(id: model.side) { await model.load() }
    }
}

struct AutomationTracePoint: Identifiable {
    let id: Int
    let value: Double
    let segment: Int
    static func points(_ values: [Double?]) -> [Self] {
        var segment = 0
        return values.enumerated().compactMap { index, value in
            guard let value, value.isFinite else { segment += 1; return nil }
            return Self(id: index, value: value, segment: segment)
        }
    }
}

struct AutomationBacktestCharts: View {
    let result: AutomationBacktest.Result
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupedCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.summary.label).font(.headline)
                    Text("Would fire \(result.summary.wouldFire) · suppressed \(result.summary.suppressed) · clamp hits \(result.summary.clampHits)").font(.footnote)
                    if let effect = result.summary.netEffect { Text(effect).font(.footnote).foregroundStyle(Theme.text2) }
                    Text(result.mode == "edge" ? "Edge replay uses a nominal temperature baseline because target history is unavailable. This is not a prediction of your bed temperature." : "Policy replay shows calculated setpoints, not measured bed temperatures.").font(.footnote).foregroundStyle(Theme.text2)
                }.padding(16)
            }
            AutomationCombinedReplayChart(result: result)
            trace("Requested temperature · °F", values: result.setpoint, threshold: nil, color: Theme.text1, axis: result.tempAxis, events: true)
            if let raw = result.setpointRaw { trace("Before limits · °F", values: raw, threshold: nil, color: Theme.text2, axis: result.tempAxis) }
            Text("Gaps mean no fresh signal was available. Green diamonds mark firings; amber crosses mark suppressed firings. Missing data is never drawn as zero.").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func trace(_ title: String, values: [Double?], threshold: Double?, color: Color, axis: AutomationBacktest.Result.Axis? = nil, events: Bool = false) -> some View {
        AutomationTraceChart(title: title, values: values, threshold: threshold, color: color, axis: axis,
                             stepMinutes: result.stepMin, fires: events ? result.fires : [], suppressed: events ? result.suppressed : [], stepped: events)
    }
}

/// Keep chart data and marks separately typed for the supported Xcode compilers.
private struct AutomationTraceChart: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let values: [Double?]
    let threshold: Double?
    let color: Color
    let axis: AutomationBacktest.Result.Axis?
    let stepMinutes: Int
    let fires: [Int]
    let suppressed: [Int]
    let stepped: Bool
    private var points: [AutomationTracePoint] { AutomationTracePoint.points(values) }
    private var bounds: ClosedRange<Double> { domain(values, threshold: threshold, axis: axis) }
    private var horizontalTicks: [Int] {
        let end = max(1, values.count - 1) * stepMinutes
        if typeSize.isAccessibilitySize { return [0, end] }
        let interval = max(1, values.count * stepMinutes / 4)
        return Array(stride(from: 0, through: end, by: interval))
    }
    private var verticalTicks: [Double] { [bounds.lowerBound, (bounds.lowerBound + bounds.upperBound) / 2, bounds.upperBound] }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.subheadline.weight(.semibold))
                if points.isEmpty { Text("No recorded values").foregroundStyle(Theme.text2) }
                else {
                    chart
                    Text("0–\(max(0, values.count - 1) * stepMinutes) minutes into replay").font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16)
        }
    }
    private var chart: some View {
        Chart { marks }.chartYScale(domain: bounds)
            .chartXAxis { AxisMarks(values: horizontalTicks) { AxisGridLine(); AxisTick(); AxisValueLabel() } }
            .chartYAxis {
                AxisMarks(values: verticalTicks) { value in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let number = value.as(Double.self) { Text(number, format: .number.precision(.fractionLength(0))) } }
                }
            }
            .frame(height: typeSize.isAccessibilitySize ? 320 : 180)
            .accessibilityLabel(title).accessibilityValue(Text("\(points.count) recorded values"))
    }
    @ChartContentBuilder private var marks: some ChartContent {
        ForEach(points) { point in
            LineMark(x: .value("Replay minute", point.id * stepMinutes), y: .value(title, point.value), series: .value("Segment", point.segment))
                .interpolationMethod(stepped ? .stepEnd : .linear).foregroundStyle(color)
        }
        ForEach(eventPoints(fires)) { point in
            PointMark(x: .value("Replay minute", point.id * stepMinutes), y: .value(title, point.value)).symbol(.diamond).foregroundStyle(Theme.green)
        }
        ForEach(eventPoints(suppressed)) { point in
            PointMark(x: .value("Replay minute", point.id * stepMinutes), y: .value(title, point.value)).symbol(.cross).foregroundStyle(Theme.amber)
        }
        if let threshold, threshold.isFinite { RuleMark(y: .value("Threshold", threshold)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Theme.text2) }
    }
    private func eventPoints(_ indices: [Int]) -> [AutomationTracePoint] {
        indices.compactMap { index in
            guard values.indices.contains(index), let value = values[index], value.isFinite else { return nil }
            return .init(id: index, value: value, segment: 0)
        }
    }
    private func domain(_ values: [Double?], threshold: Double?, axis: AutomationBacktest.Result.Axis?) -> ClosedRange<Double> {
        if let axis, axis.min.isFinite, axis.max.isFinite, axis.min < axis.max { return axis.min...axis.max }
        let finite = (values + [threshold]).compactMap { $0 }.filter(\.isFinite)
        let minimum = finite.min() ?? 0; let maximum = finite.max() ?? 1
        let padding = max(1, (maximum - minimum) * 0.1)
        return (minimum - padding)...(maximum + padding)
    }

}
