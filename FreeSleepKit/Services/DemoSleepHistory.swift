import Foundation

// Editable preview data is held in memory, separately for each side. No client or credentials are used.
@MainActor
final class DemoSleepHistory {
    private let fixture: SleepDemo?
    private var records: [SleepDemo.Record]
    var timeZone: String
    init(fixture: SleepDemo? = .shared) {
        self.fixture = fixture
        timeZone = fixture?.analytics.timeZone ?? "UTC"
        records = BedSide.allCases.flatMap { side in (fixture?.records ?? []).map { original in
            var record = original; record.side = side.rawValue; return record
        } }
    }
    func detail(id: Int, side: BedSide) throws -> EpisodeDetail {
        guard let fixture, let record = records.first(where: { $0.id == id && $0.side == side.rawValue }) else {
            throw PodError.message("This sample episode is unavailable.")
        }
        return try DemoEpisode.detail(record, fixture: fixture, timeZone: timeZone)
    }
    func analytics(side: BedSide, days: Int) -> SleepAnalytics? {
        guard let fixture else { return nil }
        let episodes = records.filter { $0.side == side.rawValue && $0.entered_bed_at >= fixture.anchor - Double(days - 1) * 86400 }
            .compactMap { try? DemoEpisode.detail($0, fixture: fixture, timeZone: timeZone).episode }.sorted { $0.startedAt < $1.startedAt }
        return DemoSleepSummary.analytics(episodes, timeZone: timeZone)
    }
    func change(id: Int, change: SleepRecordChange) throws {
        let identity = SleepRecordIdentity(side: change.side, expected: change.expected)
        let index = try index(id: id, identity: identity)
        guard let start = EpisodeDetail.date(change.entered_bed_at), let end = EpisodeDetail.date(change.left_bed_at),
              SleepRecordChange.valid(start: start, end: end) else { throw PodError.message("Choose an end after the start, within a 72-hour window.") }
        let from = floor(start.timeIntervalSince1970); let until = floor(end.timeIntervalSince1970)
        guard !records.contains(where: { $0.side == change.side.rawValue && $0.id != id && $0.entered_bed_at == from }) else {
            throw PodError.message("Another record on this side already starts at that time. Choose a different start.")
        }
        let intervals = try JSONDecoder().decode([[Double]].self, from: Data(records[index].not_present_intervals.utf8))
        records[index].entered_bed_at = from; records[index].left_bed_at = until
        records[index].sleep_period_seconds = until - from
        records[index].times_exited_bed = intervals.filter { $0.count == 2 && $0[0] >= from && $0[1] <= until }.count
    }
    func delete(id: Int, identity: SleepRecordIdentity) throws { records.remove(at: try index(id: id, identity: identity)) }
    private func index(id: Int, identity: SleepRecordIdentity) throws -> Int {
        guard let start = EpisodeDetail.date(identity.expected.entered_bed_at), let end = EpisodeDetail.date(identity.expected.left_bed_at),
              let index = records.firstIndex(where: { $0.id == id && $0.side == identity.side.rawValue }),
              records[index].entered_bed_at == floor(start.timeIntervalSince1970), records[index].left_bed_at == floor(end.timeIntervalSince1970) else {
            throw PodError.message("This record changed or was removed. Close the editor, refresh, and try again.")
        }
        return index
    }
}

private extension SleepRecordIdentity {
    init(side: BedSide, expected: Window) { self.side = side; self.expected = expected }
}

// Mirror the server's deterministic interval and chart calculations for the labelled preview.
enum DemoEpisode {
    static func detail(_ record: SleepDemo.Record, fixture: SleepDemo, timeZone: String? = nil) throws -> EpisodeDetail {
        guard var detail = fixture.details[String(record.id)] else { throw PodError.message("This sample episode is unavailable.") }
        if let timeZone { detail.timeZone = timeZone }
        let raw = (try? JSONDecoder().decode([[Double]].self, from: Data(record.present_intervals.utf8))) ?? []
        let clipped = raw.filter { $0.count == 2 && $0.allSatisfy(\.isFinite) }.map {
            [max($0[0], record.entered_bed_at), min($0[1], record.left_bed_at)]
        }.filter { $0[1] > $0[0] }.sorted { $0[0] < $1[0] }
        var intervals: [[Double]] = []
        for interval in clipped {
            if let last = intervals.last, interval[0] <= last[1] { intervals[intervals.count - 1][1] = max(last[1], interval[1]) }
            else { intervals.append(interval) }
        }
        func intervalAt(_ time: Double) -> Int? { intervals.firstIndex { time >= $0[0] && time <= $0[1] } }
        let readings = fixture.vitals.filter { $0.timestamp >= record.entered_bed_at && $0.timestamp <= record.left_bed_at }.sorted { $0.timestamp < $1.timestamp }
        detail.side = record.side
        detail.durationSeconds = record.left_bed_at - record.entered_bed_at
        detail.intervals = intervals.map { .init(start: $0[0] - record.entered_bed_at, end: $0[1] - record.entered_bed_at) }
        detail.presenceKnown = !intervals.isEmpty
        detail.samples = readings.map { .init(at: $0.timestamp, heartRate: $0.heart_rate, hrv: $0.hrv,
            respiratoryRate: $0.breathing_rate, present: intervals.isEmpty ? nil : intervalAt($0.timestamp) != nil) }
        detail.plots = detail.plots.map { template in
            var plot = template; plot.segments = []
            var values: [Double] = []; var current: [EpisodeDetail.Point] = []
            var previousTime = -Double.infinity; var previousInterval: Int?
            for reading in readings {
                let value = plot.key == "heartRate" ? reading.heart_rate : plot.key == "hrv" ? reading.hrv : reading.breathing_rate
                let bounds = plot.key == "heartRate" ? 25.0...220 : plot.key == "hrv" ? 1.0...300 : 4.0...50
                guard let value, bounds.contains(value), let interval = intervalAt(reading.timestamp) else {
                    if !current.isEmpty { plot.segments.append(current); current = [] }; continue
                }
                if !current.isEmpty && (previousInterval != interval || reading.timestamp - previousTime > 900) {
                    plot.segments.append(current); current = []
                }
                current.append(.init(seconds: reading.timestamp - record.entered_bed_at, value: value)); values.append(value)
                previousTime = reading.timestamp; previousInterval = interval
            }
            if !current.isEmpty { plot.segments.append(current) }
            plot.count = values.count; plot.average = DemoSleepSummary.mean(values); plot.minimum = values.min(); plot.maximum = values.max()
            return plot
        }
        detail.episode.startedAt = SleepRecordChange.iso(Date(timeIntervalSince1970: record.entered_bed_at))
        detail.episode.endedAt = SleepRecordChange.iso(Date(timeIntervalSince1970: record.left_bed_at))
        detail.episode.date = EpisodeDetail.clock(Date(timeIntervalSince1970: record.left_bed_at), timeZone: detail.timeZone, format: "yyyy-MM-dd")
        detail.episode.windowMinutes = DemoSleepSummary.round(detail.durationSeconds / 60)
        detail.episode.occupiedMinutes = intervals.isEmpty ? nil : DemoSleepSummary.round(intervals.reduce(0) { $0 + $1[1] - $1[0] } / 60)
        detail.episode.exits = record.times_exited_bed
        detail.episode.heartRate = detail.plots.first { $0.key == "heartRate" }?.average
        detail.episode.hrv = detail.plots.first { $0.key == "hrv" }?.average
        detail.episode.respiratoryRate = detail.plots.first { $0.key == "respiratoryRate" }?.average
        return detail
    }
}
