import Foundation
import HealthKit

struct HealthWatchSnapshot: Sendable {
    struct Stage: Codable, Hashable, Sendable { let start: Int; let end: Int; let stage: String }
    struct Heart: Codable, Hashable, Sendable { let timestamp: Int; let heartRate: Double }
    struct Sample: Codable, Hashable, Sendable { let timestamp: Int; let value: Double }
    let window: DateInterval
    let stages: [Stage]
    let heart: [Heart]
    let breathing: [Sample]
    let hrv: [Sample]
    let excluded: Int
    var count: Int { stages.count + heart.count + breathing.count + hrv.count }

    /// Only identifiable Watch sources enter the reference set; Pod writes never validate themselves.
    @MainActor static func build(samples: [HKSample], window: DateInterval) -> Self {
        let unique = Dictionary(grouping: samples, by: \.uuid).compactMap { $0.value.first }
        var stages: Set<Stage> = [], heart: Set<Heart> = [], breathing: Set<Sample> = [], hrv: Set<Sample> = []
        var excluded = 0
        for sample in unique where HealthSyncService.isWatch(sample) {
            let start = sample.startDate.timeIntervalSince1970, end = sample.endDate.timeIntervalSince1970
            guard start.isFinite, end.isFinite, start >= max(1_000_000_000, window.start.timeIntervalSince1970),
                  end <= min(4_102_444_800, window.end.timeIntervalSince1970), end >= start else { excluded += 1; continue }
            if let sample = sample as? HKCategorySample {
                guard let stage = HealthSyncService.stage(for: sample.value), Int(end) > Int(start) else { excluded += 1; continue }
                let name: String = switch stage {
                case .wake: "wake"
                case .light: "light"
                case .deep: "deep"
                case .rem: "rem"
                }
                stages.insert(.init(start: Int(start), end: Int(end), stage: name))
            } else if let sample = sample as? HKQuantitySample {
                guard [HKQuantityTypeIdentifier.heartRate.rawValue, HKQuantityTypeIdentifier.respiratoryRate.rawValue,
                       HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue].contains(sample.quantityType.identifier) else { excluded += 1; continue }
                let sdnn = sample.quantityType.identifier == HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
                let value = sample.quantity.doubleValue(for: sdnn ? .secondUnit(with: .milli) : .count().unitDivided(by: .minute()))
                guard value.isFinite else { excluded += 1; continue }
                switch sample.quantityType.identifier {
                case HKQuantityTypeIdentifier.heartRate.rawValue where (20...250).contains(value):
                    heart.insert(.init(timestamp: Int(start), heartRate: value))
                case HKQuantityTypeIdentifier.respiratoryRate.rawValue where (4...60).contains(value):
                    breathing.insert(.init(timestamp: Int(start), value: value))
                case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue where (1...500).contains(value):
                    hrv.insert(.init(timestamp: Int(start), value: value))
                default: excluded += 1
                }
            }
        }
        // Retain original boundaries for idempotent retries. Conflicting Watch segments are not guessed.
        let sorted = stages.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var conflicting: Set<Int> = [], active: [Int] = []
        for (index, segment) in sorted.enumerated() {
            active.removeAll { sorted[$0].end <= segment.start }
            if !active.isEmpty { conflicting.insert(index); conflicting.formUnion(active) }
            active.append(index)
        }
        let keptStages = sorted.enumerated().compactMap { conflicting.contains($0.offset) ? nil : $0.element }
        let keptHeart = unambiguous(Array(heart), at: \.timestamp)
        let keptBreathing = unambiguous(Array(breathing), at: \.timestamp)
        let keptHRV = unambiguous(Array(hrv), at: \.timestamp)
        excluded += conflicting.count + heart.count - keptHeart.count + breathing.count - keptBreathing.count + hrv.count - keptHRV.count
        return .init(window: window, stages: keptStages, heart: keptHeart, breathing: keptBreathing, hrv: keptHRV, excluded: excluded)
    }
    private static func unambiguous<Value>(_ values: [Value], at key: KeyPath<Value, Int>) -> [Value] {
        Dictionary(grouping: values) { $0[keyPath: key] }.values.compactMap { $0.count == 1 ? $0.first : nil }
            .sorted { $0[keyPath: key] < $1[keyPath: key] }
    }
}
