import Foundation

enum BiometricMetric: String, CaseIterable, Identifiable, Sendable {
    case heartRate, hrv, breathingRate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heartRate: "Heart rate"
        case .hrv: "HRV"
        case .breathingRate: "Breathing"
        }
    }
    var unit: String {
        switch self {
        case .heartRate: "bpm"
        case .hrv: "ms"
        case .breathingRate: "br/min"
        }
    }
    func value(_ record: VitalsRecord) -> Double? {
        let value =
            switch self {
            case .heartRate: record.heartRate
            case .hrv: record.hrv
            case .breathingRate: record.breathingRate
            }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    func text(_ value: Double?) -> String {
        value.map { String(format: self == .breathingRate ? "%.1f" : "%.0f", $0) } ?? "—"
    }
}

struct BiometricSession: Identifiable, Sendable {
    let records: [VitalsRecord]
    let stats: [BiometricMetric: BiometricPlot.Stats]
    var id: String { "\(records[0].id):\(start.timeIntervalSince1970):\(records[0].sourceKey)" }
    var start: Date { records[0].date }
    var end: Date { records[records.count - 1].date }
    var interval: ClosedRange<Date> { start...max(end, start.addingTimeInterval(60)) }
    // Sessions are observations, independent of editable sleep records. Method changes and long gaps start a new one.
    static func split(_ records: [VitalsRecord]) -> [BiometricSession] {
        var groups: [[VitalsRecord]] = []
        for record in records.sorted(by: { $0.date < $1.date })
        where BiometricMetric.allCases.contains(where: { $0.value(record) != nil }) {
            if let previous = groups.last?.last, record.date.timeIntervalSince(previous.date) <= 1800,
                previous.sourceKey == record.sourceKey, previous.hrvMetricID == record.hrvMetricID {
                groups[groups.count - 1].append(record)
            } else {
                groups.append([record])
            }
        }
        return groups.map { readings in
            .init(
                records: readings,
                stats: Dictionary(
                    uniqueKeysWithValues: BiometricMetric.allCases.compactMap { metric in
                        BiometricPlot(metric: metric, records: readings).stats.map { (metric, $0) }
                    }))
        }
    }
}

/// Piecewise time mapping reserves visible breaks between sessions without inventing observations in the gaps.
struct BiometricTimeAxis: Sendable {
    struct Segment: Sendable {
        let dates: ClosedRange<Date>
        let lower: Double
        let upper: Double
    }
    let segments: [Segment]
    let collapsed: Bool
    static func intervals(dates: [Date], sampleDuration: TimeInterval = 60) -> [ClosedRange<Date>] {
        var result: [ClosedRange<Date>] = []
        var previous: Date?
        for date in dates.sorted() {
            let end = date.addingTimeInterval(max(1, sampleDuration.isFinite ? sampleDuration : 60))
            if let last = result.last, let previous, date.timeIntervalSince(previous) <= 1800 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                result.append(date...end)
            }
            previous = date
        }
        return result
    }
    init(intervals: [ClosedRange<Date>], window: ClosedRange<Date>, collapse: Bool) {
        var merged: [ClosedRange<Date>] = []
        if collapse {
            for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let lower = max(window.lowerBound, interval.lowerBound)
                let upper = min(window.upperBound, interval.upperBound)
                guard lower < upper else { continue }
                if let last = merged.last, lower <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, upper)
                } else {
                    merged.append(lower...upper)
                }
            }
        }
        collapsed = collapse && merged.count > 1
        if merged.isEmpty || !collapse { merged = [window] }
        let gaps = max(0, merged.count - 1)
        let breakWidth = gaps == 0 ? 0 : min(0.06, 0.20 / Double(gaps))
        let available = 1 - breakWidth * Double(gaps)
        let total = merged.reduce(0) { $0 + max(60, $1.upperBound.timeIntervalSince($1.lowerBound)) }
        var position = 0.0
        segments = merged.map { dates in
            let width = available * max(60, dates.upperBound.timeIntervalSince(dates.lowerBound)) / max(1, total)
            let segment = Segment(dates: dates, lower: position, upper: position + width)
            position += width + breakWidth
            return segment
        }
    }
    func position(_ date: Date) -> Double {
        guard let first = segments.first, let last = segments.last else { return 0 }
        if date <= first.dates.lowerBound { return 0 }
        if date >= last.dates.upperBound { return 1 }
        for (index, segment) in segments.enumerated() {
            if segment.dates.contains(date) {
                let fraction =
                    date.timeIntervalSince(segment.dates.lowerBound)
                    / max(1, segment.dates.upperBound.timeIntervalSince(segment.dates.lowerBound))
                return segment.lower + fraction * (segment.upper - segment.lower)
            }
            if index + 1 < segments.count, date < segments[index + 1].dates.lowerBound {
                let next = segments[index + 1]
                let fraction =
                    date.timeIntervalSince(segment.dates.upperBound)
                    / max(1, next.dates.lowerBound.timeIntervalSince(segment.dates.upperBound))
                return segment.upper + fraction * (next.lower - segment.upper)
            }
        }
        return 1
    }
    func date(at position: Double, snappingGaps: Bool = true) -> Date? {
        guard position.isFinite, let first = segments.first, let last = segments.last else { return nil }
        if position <= 0 { return first.dates.lowerBound }
        if position >= 1 { return last.dates.upperBound }
        for (index, segment) in segments.enumerated() {
            if position <= segment.upper {
                let fraction = max(0, position - segment.lower) / max(0.000001, segment.upper - segment.lower)
                return segment.dates.lowerBound.addingTimeInterval(
                    fraction * segment.dates.upperBound.timeIntervalSince(segment.dates.lowerBound))
            }
            if index + 1 < segments.count, position < segments[index + 1].lower {
                let next = segments[index + 1]
                if !snappingGaps {
                    let fraction = (position - segment.upper) / max(0.000001, next.lower - segment.upper)
                    return segment.dates.upperBound.addingTimeInterval(
                        fraction * next.dates.lowerBound.timeIntervalSince(segment.dates.upperBound))
                }
                return position - segment.upper <= next.lower - position
                    ? segment.dates.upperBound : next.dates.lowerBound
            }
        }
        return last.dates.upperBound
    }
    var breaks: [Double] { zip(segments, segments.dropFirst()).map { ($0.upper + $1.lower) / 2 } }
    func segmentIndex(containing date: Date) -> Int? { segments.firstIndex { $0.dates.contains(date) } }
}

struct BiometricPlot: Sendable {
    struct Point: Identifiable, Sendable {
        let id: Int
        let date: Date
        let value: Double
        var smooth: Double
        let segment: Int
    }
    struct Stats: Sendable {
        let minimum: Double
        let maximum: Double
        let average: Double
        let lower: Double
        let upper: Double
    }
    let metric: BiometricMetric
    let points: [Point]
    let stats: Stats?
    let mixedSources: Bool
    init(metric: BiometricMetric, records: [VitalsRecord]) {
        self.metric = metric
        let sorted = records.sorted { $0.date < $1.date }
        let relevant = sorted.filter { metric.value($0) != nil }
        let sources = Set(relevant.map { $0.sourceKey + (metric == .hrv ? ":" + ($0.hrvMetricID ?? "unknown") : "") })
        mixedSources = sources.count > 1
        let values = relevant.compactMap { metric.value($0) }.sorted()
        if !values.isEmpty && !mixedSources {
            stats = Stats(
                minimum: values[0], maximum: values[values.count - 1],
                average: values.reduce(0, +) / Double(values.count),
                lower: Self.percentile(values, fraction: 0.25), upper: Self.percentile(values, fraction: 0.75))
        } else {
            stats = nil
        }
        var segments: [[Point]] = []
        var previous: VitalsRecord?
        var pendingBreak = true
        for record in sorted {
            guard let value = metric.value(record) else {
                pendingBreak = true
                continue
            }
            let sameSource =
                previous.map {
                    $0.sourceKey == record.sourceKey && (metric != .hrv || $0.hrvMetricID == record.hrvMetricID)
                } ?? false
            let close = previous.map { record.date.timeIntervalSince($0.date) <= 30 * 60 } ?? false
            if pendingBreak || !sameSource || !close { segments.append([]) }
            segments[segments.count - 1].append(
                Point(id: record.id, date: record.date, value: value, smooth: value, segment: segments.count - 1))
            previous = record
            pendingBreak = false
        }
        points = segments.flatMap(Self.smooth)
    }
    // A sliding window is linear in the number of readings and never crosses missing data or a processing-run boundary.
    private static func smooth(_ points: [Point]) -> [Point] {
        var result = points
        var lower = 0
        var upper = 0
        var sum = 0.0
        for index in points.indices {
            let center = points[index].date
            while upper < points.count && points[upper].date.timeIntervalSince(center) <= 270 {
                sum += points[upper].value
                upper += 1
            }
            while lower < upper && center.timeIntervalSince(points[lower].date) > 270 {
                sum -= points[lower].value
                lower += 1
            }
            result[index].smooth = sum / Double(max(1, upper - lower))
        }
        return result
    }
    /// Retain extrema and segment ends for rendering; exports and selection keep every original reading.
    func displayPoints(in window: ClosedRange<Date>, budget: Int = 1500) -> [Point] {
        let visible = points.filter { window.contains($0.date) }
        guard visible.count > budget else { return visible }
        let bucketSize = max(1, Int(ceil(Double(visible.count) / Double(budget / 4))))
        var keep: Set<Int> = []
        for start in stride(from: 0, to: visible.count, by: bucketSize) {
            let end = min(start + bucketSize, visible.count)
            let indices = start..<end
            keep.insert(start)
            keep.insert(end - 1)
            if let low = indices.min(by: { visible[$0].value < visible[$1].value }) { keep.insert(low) }
            if let high = indices.max(by: { visible[$0].value < visible[$1].value }) { keep.insert(high) }
        }
        return keep.sorted().map { visible[$0] }
    }
    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        let position = Double(values.count - 1) * fraction
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }
}

struct BiometricViewport: Sendable, Equatable {
    let full: ClosedRange<Date>
    private(set) var window: ClosedRange<Date>
    var zoom: Double {
        full.upperBound.timeIntervalSince(full.lowerBound)
            / max(1, window.upperBound.timeIntervalSince(window.lowerBound))
    }
    func zoom(using axis: BiometricTimeAxis) -> Double {
        1 / max(0.000001, axis.position(window.upperBound) - axis.position(window.lowerBound))
    }
    init(start: Date, end: Date) {
        full = start...max(end, start.addingTimeInterval(60))
        window = full
    }
    mutating func scale(_ factor: Double, anchor: Date? = nil) {
        guard factor.isFinite && factor > 0 else { return }
        let duration = full.upperBound.timeIntervalSince(full.lowerBound)
        let span = min(duration, max(duration / 16, window.upperBound.timeIntervalSince(window.lowerBound) / factor))
        let center =
            anchor ?? window.lowerBound.addingTimeInterval(window.upperBound.timeIntervalSince(window.lowerBound) / 2)
        set(start: center.addingTimeInterval(-span / 2), span: span)
    }
    mutating func pan(_ direction: Double) {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        set(start: window.lowerBound.addingTimeInterval(span * 0.7 * direction), span: span)
    }
    mutating func select(_ range: ClosedRange<Date>) {
        let minimum = full.upperBound.timeIntervalSince(full.lowerBound) / 16
        set(start: range.lowerBound, span: max(minimum, range.upperBound.timeIntervalSince(range.lowerBound)))
    }
    mutating func reset() { window = full }
    mutating func scale(_ factor: Double, anchor: Date? = nil, using axis: BiometricTimeAxis) {
        guard factor.isFinite && factor > 0 else { return }
        let lower = axis.position(window.lowerBound)
        let upper = axis.position(window.upperBound)
        // A focused short session may already exceed the normal zoom limit. A pinch-in must never zoom it back out.
        if factor > 1, upper - lower <= 1.0 / 16 { return }
        let minimum = factor > 1 ? 1.0 / 16 : min(1.0 / 16, upper - lower)
        let span = min(1, max(minimum, (upper - lower) / factor))
        let center = anchor.map(axis.position) ?? (lower + upper) / 2
        setMapped(start: center - span / 2, span: span, axis: axis)
    }
    mutating func pan(_ direction: Double, using axis: BiometricTimeAxis) {
        guard direction.isFinite else { return }
        let lower = axis.position(window.lowerBound)
        let upper = axis.position(window.upperBound)
        setMapped(start: lower + (upper - lower) * 0.7 * direction, span: upper - lower, axis: axis)
    }
    mutating func focus(_ range: ClosedRange<Date>) {
        set(start: range.lowerBound, span: max(60, range.upperBound.timeIntervalSince(range.lowerBound)))
    }
    private mutating func setMapped(start: Double, span: Double, axis: BiometricTimeAxis) {
        let lower = min(max(0, start), max(0, 1 - span))
        // Navigation can end inside a gap; snapping these bounds would change the requested zoom on every pan.
        guard let start = axis.date(at: lower, snappingGaps: false),
            let end = axis.date(at: lower + span, snappingGaps: false), end > start
        else { return }
        window = max(full.lowerBound, start)...min(full.upperBound, end)
    }
    private mutating func set(start: Date, span: Double) {
        let bounded = min(span, full.upperBound.timeIntervalSince(full.lowerBound))
        let lower = max(full.lowerBound, min(start, full.upperBound.addingTimeInterval(-bounded)))
        window = lower...lower.addingTimeInterval(bounded)
    }
}

enum BiometricRange: String, CaseIterable, Identifiable {
    case night = "Night"
    case week = "Week"
    case month = "Month"
    var id: String { rawValue }
    func window(through date: Date, calendar: Calendar) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        if self == .night {
            let start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        }
        let start = calendar.date(byAdding: .day, value: self == .week ? -6 : -29, to: day) ?? day
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
    }
}
