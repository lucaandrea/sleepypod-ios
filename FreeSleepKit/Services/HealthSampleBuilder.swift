import Foundation
import HealthKit

enum HealthSampleBuilder {
    // Canonical timestamps and merged intervals make repeat exports stable even if source formatting changes.
    static func presence(_ records: [HealthExportRecords.Sleep], pod: String, side: BedSide, version: Int) -> [HKSample] {
        records.flatMap { record in
            let intervals = record.present_intervals.compactMap { interval -> DateInterval? in
                guard interval.count == 2, let start = date(interval[0]), let end = date(interval[1]), end > start else { return nil }
                return DateInterval(start: start, end: end)
            }.sorted { $0.start < $1.start }
            var merged: [DateInterval] = []
            for interval in intervals {
                if let previous = merged.last, previous.end >= interval.start {
                    merged[merged.count - 1] = DateInterval(start: previous.start, end: max(previous.end, interval.end))
                } else { merged.append(interval) }
            }
            return merged.map { interval in
                let identifier = "\(pod):\(side.rawValue):presence:\(record.id):\(Int(interval.start.timeIntervalSince1970))"
                return HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                    start: interval.start, end: interval.end, metadata: metadata(identifier: identifier, pod: pod, side: side, version: version))
            }
        }
    }
    static func heart(_ records: [HealthExportRecords.Vital], pod: String, side: BedSide, version: Int) -> [HKSample] {
        records.compactMap { record in
            guard let value = record.heart_rate, value.isFinite, (25...220).contains(value), let timestamp = date(record.timestamp) else { return nil }
            return HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: value),
                start: timestamp, end: timestamp, metadata: metadata(identifier: "\(pod):\(side.rawValue):heart:\(record.id)", pod: pod, side: side, version: version))
        }
    }
    static func date(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
    private static func metadata(identifier: String, pod: String, side: BedSide, version: Int) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: identifier, HKMetadataKeySyncVersion: version,
         "FreeSleepPod": pod, "FreeSleepSide": side.rawValue, "FreeSleepSource": "Pod presence/vitals"]
    }
}
