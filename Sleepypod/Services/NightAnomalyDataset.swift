import CryptoKit
import Foundation

/// Source-separated Health intervals. A long daily total is never used as proof of an intact night.
enum NightAnomalyDataset {
    struct Sample: Sendable {
        let id: String
        let sourceID: String
        let sourceName: String
        let start: Date
        let end: Date
        let category: Int // Health: 0 in bed, 1 unspecified sleep, 2 awake, 3–5 measured stages.
    }

    struct Audit: Sendable {
        var nights: [NightAnomalyObservation] = []
        var exclusions: [String: Int] = [:]
    }

    static func build(_ samples: [Sample], calendar: Calendar, now: Date) -> Audit {
        var audit = Audit()
        let unique = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let valid = unique.filter { sample in
            guard sample.category != 0 else { return false }
            guard (1...5).contains(sample.category), sample.end > sample.start,
                  sample.start.timeIntervalSince1970.isFinite, sample.end.timeIntervalSince1970.isFinite else {
                audit.exclusions["Invalid interval", default: 0] += 1; return false
            }
            return true
        }
        // Keep each source/device and noon-to-noon recording day separate, including DST transitions.
        let groups = Dictionary(grouping: valid) { sample in
            let shifted = calendar.date(byAdding: .hour, value: -12, to: sample.start) ?? sample.start
            return sample.sourceID + "|" + String(calendar.startOfDay(for: shifted).timeIntervalSince1970)
        }
        for group in groups.values {
            let ordered = group.sorted { $0.start < $1.start }
            var clusters: [[Sample]] = []
            for sample in ordered {
                if let previous = clusters.last, let end = previous.map(\.end).max(), sample.start.timeIntervalSince(end) <= 1800 {
                    clusters[clusters.count - 1].append(sample)
                } else { clusters.append([sample]) }
            }
            var candidates: [NightAnomalyObservation] = []
            for cluster in clusters {
                do { candidates.append(try observation(cluster, calendar: calendar, now: now)) }
                catch { audit.exclusions[error.localizedDescription, default: 0] += 1 }
            }
            if candidates.count > 1 { audit.exclusions["More than one possible main sleep period", default: 0] += candidates.count }
            else { audit.nights += candidates }
        }
        audit.nights.sort { $0.start > $1.start }
        return audit
    }

    private struct Exclusion: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    private static func observation(_ samples: [Sample], calendar: Calendar, now: Date) throws -> NightAnomalyObservation {
        guard let first = samples.first, let start = samples.map(\.start).min(), let end = samples.map(\.end).max() else {
            throw Exclusion(reason: "Empty recording")
        }
        let window = DateInterval(start: start, end: end)
        guard (6 * 3600...12 * 3600).contains(window.duration) else { throw Exclusion(reason: "Recording outside 6–12 hours") }
        guard end <= now.addingTimeInterval(-3600) else { throw Exclusion(reason: "Recording still settling") }
        for (index, sample) in samples.enumerated() {
            for later in samples.dropFirst(index + 1) {
                if later.start >= sample.end { break }
                let different = sample.category != later.category
                let incompatible = sample.category == 2 || later.category == 2 || (sample.category >= 3 && later.category >= 3)
                if different && incompatible { throw Exclusion(reason: "Conflicting sleep stages") }
            }
        }
        let intervals = samples.map { DateInterval(start: $0.start, end: $0.end) }
        if let issue = StageTrainingCoverage.issue(intervals, within: window) { throw Exclusion(reason: issue) }
        let covered = StageTrainingCoverage.merged(intervals, within: window)
        let sleep = StageTrainingCoverage.merged(samples.filter { $0.category != 2 }.map { DateInterval(start: $0.start, end: $0.end) }, within: window)
        let sleepMinutes = sleep.reduce(0) { $0 + $1.duration } / 60
        guard sleepMinutes >= 360 else { throw Exclusion(reason: "Less than six recorded sleep hours") }
        let midpoint = start.addingTimeInterval(window.duration / 2)
        let clock = calendar.dateComponents([.hour, .minute], from: midpoint)
        var values = ["sleepMinutes": sleepMinutes, "midpointMinutes": Double((clock.hour ?? 0) * 60 + (clock.minute ?? 0))]
        // Summary-only sources cannot establish that unreported awake time equals zero.
        if samples.allSatisfy({ $0.category >= 2 }) {
            let awake = StageTrainingCoverage.merged(samples.filter { $0.category == 2 }.map { DateInterval(start: $0.start, end: $0.end) }, within: window)
            values["awakeFraction"] = awake.reduce(0) { $0 + $1.duration } / covered.reduce(0) { $0 + $1.duration }
        }
        let gap = zip(covered, covered.dropFirst()).map { $1.start.timeIntervalSince($0.end) / 60 }.max() ?? 0
        let evidence = samples.map { "\($0.id)|\($0.start.timeIntervalSince1970)|\($0.end.timeIntervalSince1970)|\($0.category)" }.sorted().joined(separator: "\n")
        return .init(id: first.sourceID + "|" + String(start.timeIntervalSince1970), sourceID: first.sourceID, sourceName: first.sourceName,
                     start: start, end: end, values: values, coverage: covered.reduce(0) { $0 + $1.duration } / window.duration,
                     maximumGapMinutes: gap, sampleCount: samples.count, evidenceDigest: digest(evidence))
    }

    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
