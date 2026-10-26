import Charts
import SwiftUI

struct CalibrationSignalChart: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let kind: CalibrationKind
    let side: Side
    let profile: SensorCalibrationProfile?
    let buffer: CalibrationSignalBuffer
    let now: Date
    @State private var position = 1.0
    private struct Point { let time: Date; let value: Double; let series: String }
    private var start: Date { now.addingTimeInterval(kind == .temperature ? -600 : -30) }
    private var selected: Date { start.addingTimeInterval(now.timeIntervalSince(start) * position) }
    private func temperature(_ value: Double) -> Double { settings.temperatureFormat == .celsius ? value : value * 9 / 5 + 32 }
    private var points: [Point] {
        switch kind {
        case .piezo:
            return CalibrationSignalBuffer.envelope((buffer.piezo[side] ?? []).filter { $0.time >= start }).flatMap {
                [Point(time: $0.time, value: $0.low, series: "Waveform"), Point(time: $0.time, value: $0.high, series: "Waveform")]
            }
        case .capacitance:
            let calibration = profile?.parameters?.capacitance
            return (buffer.capacitance[side] ?? []).filter { $0.time >= start }.flatMap { frame -> [Point] in
                if let calibration {
                    guard let values = calibration.deviation(frame.values) else { return [] }
                    return values.enumerated().map { Point(time: frame.time, value: $0.element, series: ["A", "B", "C"][$0.offset]) }
                        + [Point(time: frame.time, value: values.reduce(0, +), series: "Sum")]
                }
                guard let value = frame.values.first, value.isFinite, value != -1 else { return [] }
                return [Point(time: frame.time, value: value, series: "Raw")]
            }
        case .temperature:
            return (buffer.temperature[side] ?? []).filter { $0.time >= start }.flatMap { frame in
                frame.zones.enumerated().compactMap { index, value in
                    value.map { Point(time: frame.time, value: temperature($0), series: ["Outer", "Center", "Inner"][index]) }
                }
            }
        }
    }
    private var band: ClosedRange<Double>? {
        switch kind {
        case .piezo:
            return profile?.parameters?.piezo.map { (-$0.noise / 2)...($0.noise / 2) }
        case .capacitance:
            return profile?.parameters?.capacitance.map { (-$0.band)...$0.band }
        case .temperature:
            let values = profile?.parameters?.temperatureMeans(side: side).values ?? [String: Double]().values
            guard let low = values.min(), let high = values.max() else { return nil }
            return temperature(low - 0.25)...temperature(high + 0.25)
        }
    }
    private var thresholds: [Double] {
        if kind == .piezo, let value = profile?.parameters?.piezo?.threshold { return [-value / 2, value / 2] }
        if kind == .capacitance, let value = profile?.parameters?.capacitance?.threshold { return [value] }
        return []
    }
    private var seriesNames: [String] {
        switch kind {
        case .piezo: ["Waveform"]
        case .capacitance: profile?.parameters?.capacitance == nil ? ["Raw"] : ["A", "B", "C", "Sum"]
        case .temperature: ["Outer", "Center", "Inner"]
        }
    }
    private var palette: [Color] { kind == .piezo ? [Theme.purple] : [Theme.cool, Theme.amber, Theme.green, Theme.purple] }
    var body: some View {
        let points = points
        VStack(alignment: .leading, spacing: 10) {
            if points.isEmpty {
                Text("Waiting for \(side.displayName.lowercased()) \(kind.rawValue) samples…").font(.footnote).foregroundStyle(Theme.text2)
            } else {
                Chart {
                    if let band {
                        RectangleMark(xStart: .value("Start", start), xEnd: .value("Now", now), yStart: .value("Baseline low", band.lowerBound), yEnd: .value("Baseline high", band.upperBound))
                            .foregroundStyle(Theme.text2.opacity(0.13))
                    }
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Time", point.time), y: .value("Reading", point.value), series: .value("Signal", point.series))
                            .foregroundStyle(by: .value("Signal", point.series))
                    }
                    ForEach(thresholds, id: \.self) { value in
                        RuleMark(y: .value("Presence threshold", value)).lineStyle(.init(lineWidth: 1, dash: [4, 4])).foregroundStyle(Theme.text2)
                    }
                    RuleMark(x: .value("Inspect", selected)).foregroundStyle(Theme.text1.opacity(0.5))
                }.chartXScale(domain: start...now).chartXAxis(.hidden).chartYScale(domain: verticalRange(points))
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) { Text(compact(number)).font(.caption2).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: seriesNames, range: palette)
                    .chartLegend(.hidden)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 220 : 140)
                    .accessibilityLabel("\(kind.title) recent signal and calibration baseline")
                LazyVGrid(columns: [.init(dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Array(seriesNames.enumerated()), id: \.element) { index, name in
                        Label { Text(name) } icon: { Circle().fill(palette[index]).frame(width: 8, height: 8) }.font(.caption)
                    }
                }
                Text(kind == .temperature ? "Surface temperature · \(settings.temperatureFormat == .celsius ? "°C" : "°F") · last 10 minutes" : kind == .piezo ? "Centered waveform · last 30 seconds" : "Capacitance · last 30 seconds")
                    .font(.caption).foregroundStyle(Theme.text2)
                Text(currentSummary).font(.caption.monospacedDigit()).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Text(readout(points)).font(.caption.monospacedDigit()).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("calibration.signalReadout.\(kind.rawValue)")
                Slider(value: $position, in: 0...1).accessibilityLabel("Inspect \(kind.title.lowercased()) signal").accessibilityValue(readout(points))
                if let latest = points.map(\.time).max(), now.timeIntervalSince(latest) > (kind == .temperature ? 60 : 5) {
                    Text("Signal is stale. Last sample \(latest.formatted(date: .omitted, time: .standard)).").font(.caption).foregroundStyle(Theme.amber)
                }
            }
            if band != nil { Text(kind == .temperature ? "Shaded band: last calibration." : "Shaded band: last calibration. Dashed lines: presence threshold.").font(.caption).foregroundStyle(Theme.text2) }
            else { Text("No supported calibration baseline is available.").font(.caption).foregroundStyle(Theme.text2) }
        }
    }
    private func verticalRange(_ points: [Point]) -> ClosedRange<Double> {
        let values = points.map(\.value) + thresholds + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
        guard let low = values.min(), let high = values.max() else { return -1...1 }
        let padding = kind == .temperature ? (settings.temperatureFormat == .celsius ? 0.5 : 0.9) : max((high - low) * 0.1, 0.5)
        return (low - padding)...(high + padding)
    }
    private func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    // Explain the latest live reading against the stored baseline without claiming a fresh occupancy decision.
    private var currentSummary: String {
        switch kind {
        case .piezo:
            guard let frame = buffer.piezo[side]?.last, let range = CalibrationSignalBuffer.range(frame.samples) else { return "No latest reading" }
            guard let baseline = profile?.parameters?.piezo else { return "Range \(compact(range)) · not calibrated" }
            return "Range \(compact(range)) · \(range > baseline.threshold ? "above" : "below") presence threshold \(compact(baseline.threshold))"
        case .capacitance:
            guard let frame = buffer.capacitance[side]?.last, let baseline = profile?.parameters?.capacitance,
                  let values = baseline.deviation(frame.values), let count = baseline.channelsInBaseline(frame.values) else { return "Raw reading · no supported baseline" }
            return "Sum \(compact(values.reduce(0, +))) · threshold \(compact(baseline.threshold)) · \(count) of 3 channels in baseline"
        case .temperature:
            guard let frame = buffer.temperature[side]?.last, frame.zones.indices.contains(1), let center = frame.zones[1] else { return "Center reading unavailable" }
            let unit = settings.temperatureFormat == .celsius ? "°C" : "°F"
            let current = "Center \(temperature(center).formatted(.number.precision(.fractionLength(1))))\(unit)"
            guard let baseline = profile?.parameters?.temperatureMeans(side: side)["center"] else { return "\(current) · not calibrated" }
            return "\(current) · calibrated \(temperature(baseline).formatted(.number.precision(.fractionLength(1))))\(unit)"
        }
    }
    private func readout(_ points: [Point]) -> String {
        if kind == .piezo {
            let frames = buffer.piezo[side] ?? []
            let nearest = frames.min { abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected)) }
            if let nearest, abs(nearest.time.timeIntervalSince(selected)) <= 2, let range = CalibrationSignalBuffer.range(nearest.samples) {
                return "\(selected.formatted(date: .omitted, time: .standard)) · range \(compact(range))"
            }
            return "\(selected.formatted(date: .omitted, time: .standard)) · No sample near this time"
        }
        let series = Set(points.map(\.series)).sorted()
        let values = series.compactMap { name -> String? in
            let candidates = points.filter { $0.series == name }
            guard let point = candidates.min(by: { abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected)) }),
                  abs(point.time.timeIntervalSince(selected)) <= (kind == .temperature ? 30 : 2) else { return nil }
            return "\(name) \(point.value.formatted(.number.precision(.fractionLength(0...2))))"
        }
        return "\(selected.formatted(date: .omitted, time: .standard)) · \(values.isEmpty ? "No sample near this time" : values.joined(separator: " · "))"
    }
}
