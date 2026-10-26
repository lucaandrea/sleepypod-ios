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
    @Environment(\.dynamicTypeSize) private var typeSize
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
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.subheadline.weight(.semibold))
                if AutomationTracePoint.points(values).isEmpty { Text("No recorded values").foregroundStyle(Theme.text2) }
                else {
                    Chart {
                        ForEach(AutomationTracePoint.points(values)) { point in
                            LineMark(x: .value("Replay minute", point.id * result.stepMin), y: .value(title, point.value), series: .value("Segment", point.segment))
                                .interpolationMethod(events ? .stepEnd : .linear).foregroundStyle(color)
                        }
                        if events {
                            ForEach(result.fires, id: \.self) { index in
                                if values.indices.contains(index), let value = values[index], value.isFinite {
                                    PointMark(x: .value("Replay minute", index * result.stepMin), y: .value(title, value)).symbol(.diamond).foregroundStyle(Theme.green)
                                }
                            }
                            ForEach(result.suppressed, id: \.self) { index in
                                if values.indices.contains(index), let value = values[index], value.isFinite {
                                    PointMark(x: .value("Replay minute", index * result.stepMin), y: .value(title, value)).symbol(.cross).foregroundStyle(Theme.amber)
                                }
                            }
                        }
                        if let threshold, threshold.isFinite { RuleMark(y: .value("Threshold", threshold)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Theme.text2) }
                    }.chartYScale(domain: domain(values, threshold: threshold, axis: axis))
                        .chartXAxis {
                            AxisMarks(values: typeSize.isAccessibilitySize ? [0, max(1, values.count - 1) * result.stepMin] : stride(from: 0, through: max(1, values.count - 1) * result.stepMin, by: max(1, values.count * result.stepMin / 4)).map { $0 }) {
                                AxisGridLine(); AxisTick(); AxisValueLabel()
                            }
                        }
                        .chartYAxis {
                            let bounds = domain(values, threshold: threshold, axis: axis)
                            AxisMarks(values: [bounds.lowerBound, (bounds.lowerBound + bounds.upperBound) / 2, bounds.upperBound]) { value in
                                AxisGridLine(); AxisTick()
                                AxisValueLabel {
                                    if let number = value.as(Double.self) { Text(number, format: .number.precision(.fractionLength(0))) }
                                }
                            }
                        }
                        .frame(height: typeSize.isAccessibilitySize ? 320 : 180)
                        .accessibilityLabel(title).accessibilityValue(Text("\(AutomationTracePoint.points(values).count) recorded values"))
                    Text("0–\(max(0, values.count - 1) * result.stepMin) minutes into replay").font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16)
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
