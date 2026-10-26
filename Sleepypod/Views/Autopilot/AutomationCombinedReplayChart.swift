import Charts
import SwiftUI

struct AutomationCombinedReplayChart: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let result: AutomationBacktest.Result
    private struct Trace: Identifiable {
        let id: String
        let values: [Double?]
        let color: Color
        var stepped = false
        var dashed = false
    }
    private var policy: Bool { result.mode == "policy" }
    private var traces: [Trace] {
        var values: [Trace] = []
        if let primary = result.primary { values.append(.init(id: primary.label, values: primary.values, color: Theme.cool)) }
        if let average = result.avg { values.append(.init(id: average.label, values: average.values, color: Theme.violet)) }
        if policy {
            values.append(.init(id: "Requested °F", values: result.setpoint, color: Theme.text1, stepped: true))
            if let raw = result.setpointRaw { values.append(.init(id: "Before limits °F", values: raw, color: Theme.text2, dashed: true)) }
        }
        return values
    }
    private var duration: Int { max(1, result.clockMin.count - 1) * result.stepMin }
    private var bounds: ClosedRange<Double> {
        let axisValues = [result.primaryAxis?.min, result.primaryAxis?.max, policy ? result.tempAxis?.min : nil, policy ? result.tempAxis?.max : nil, policy ? result.clamp?.min : nil, policy ? result.clamp?.max : nil, result.threshold]
        let values = traces.flatMap(\.values).compactMap { $0 }.filter(\.isFinite) + axisValues.compactMap { $0 }.filter(\.isFinite)
        let lower = values.min() ?? 0; let upper = values.max() ?? 1
        return lower...max(lower + 1, upper)
    }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(policy ? "Signals and requested temperature" : "Compared signals").font(.headline)
                if traces.allSatisfy({ AutomationTracePoint.points($0.values).isEmpty }) {
                    Text("No fresh compared values in this replay.").foregroundStyle(Theme.text2)
                } else {
                    Chart {
                        ForEach(Array(AutomationReplaySpans.timeWindows(result).enumerated()), id: \.offset) { _, span in
                            RectangleMark(xStart: .value("From", span.lowerBound * result.stepMin), xEnd: .value("Until", min(duration, (span.upperBound + 1) * result.stepMin)), yStart: .value("Low", bounds.lowerBound), yEnd: .value("High", bounds.upperBound)).foregroundStyle(Theme.text1.opacity(0.07))
                        }
                        if policy, let clamp = result.clamp {
                            RectangleMark(xStart: .value("From", 0), xEnd: .value("Until", duration), yStart: .value("Low", max(bounds.lowerBound, clamp.min)), yEnd: .value("High", min(bounds.upperBound, clamp.max))).foregroundStyle(Theme.cool.opacity(0.1))
                            RuleMark(y: .value("Minimum", clamp.min)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Theme.cool)
                            RuleMark(y: .value("Maximum", clamp.max)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Theme.cool)
                        }
                        ForEach(traces) { trace in
                            ForEach(AutomationTracePoint.points(trace.values)) { point in
                                LineMark(x: .value("Replay minute", point.id * result.stepMin), y: .value("Value", point.value), series: .value("Segment", "\(trace.id)-\(point.segment)"))
                                    .interpolationMethod(trace.stepped ? .stepEnd : .linear).foregroundStyle(trace.color)
                                    .lineStyle(StrokeStyle(lineWidth: trace.stepped ? 2 : 1.5, dash: trace.dashed ? [4, 3] : []))
                            }
                        }
                        if !policy, let threshold = result.threshold { RuleMark(y: .value("Threshold", threshold)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.amber) }
                    }.chartXScale(domain: 0...duration).chartYScale(domain: bounds)
                        .chartXAxis { AxisMarks(values: [0, duration / 2, duration]) }
                        .chartYAxis { AxisMarks(values: [bounds.lowerBound, (bounds.lowerBound + bounds.upperBound) / 2, bounds.upperBound]) }
                        .frame(height: typeSize.isAccessibilitySize ? 320 : 200)
                        .accessibilityIdentifier("automation.combinedPlot")
                    ForEach(traces) { trace in Text(trace.id).font(.caption).foregroundStyle(trace.color) }
                }
                Text("0–\(duration) minutes into replay. Shading marks the reported time window.").font(.caption).foregroundStyle(Theme.text2)
                if let clamp = result.clamp, policy { Text("Temperature limits: \(clamp.min.formatted())–\(clamp.max.formatted())°F. All temperature traces share one axis.").font(.caption).foregroundStyle(Theme.text2) }
                if let threshold = result.threshold, !policy { Text("Compared threshold: \(threshold.formatted())").font(.caption).foregroundStyle(Theme.amber) }
                eventRail
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private var eventRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Firing and suppression").font(.subheadline)
            Chart {
                ForEach(Array(AutomationReplaySpans.grouped(result.suppressed, count: result.clockMin.count).enumerated()), id: \.offset) { _, span in
                    RectangleMark(xStart: .value("From", max(0, span.lowerBound * result.stepMin - result.stepMin / 2)), xEnd: .value("Until", min(duration, (span.upperBound + 1) * result.stepMin)), yStart: .value("Lower", 0.15), yEnd: .value("Upper", 0.85)).foregroundStyle(Theme.amber.opacity(0.5))
                }
                ForEach(Array(Set(result.fires)).sorted(), id: \.self) { index in
                    if result.clockMin.indices.contains(index) { PointMark(x: .value("Replay minute", index * result.stepMin), y: .value("Firing", 0.5)).symbol(.diamond).foregroundStyle(Theme.green) }
                }
            }.chartXScale(domain: 0...duration).chartYScale(domain: 0...1).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 30)
                .accessibilityLabel("Replay events").accessibilityValue("\(result.fires.count) firings, \(result.suppressed.count) suppressed checks")
            Text("Green diamonds: rule firings · amber spans: suppressed checks. Replay sends no commands.").font(.caption).foregroundStyle(Theme.text2)
        }
    }
}
