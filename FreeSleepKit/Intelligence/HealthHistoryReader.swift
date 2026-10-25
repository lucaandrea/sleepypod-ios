import Foundation
import HealthKit

@MainActor
struct HealthHistoryReader {
    let store: HKHealthStore
    static let quantities: [HKQuantityTypeIdentifier] = [.restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate]
    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw PodError.message("Health is unavailable on this device.") }
        let types: Set<HKObjectType> = Set(Self.quantities.map { HKQuantityType($0) } + [HKCategoryType(.sleepAnalysis)])
        try await store.requestAuthorization(toShare: [], read: types)
    }
    func read(now: Date = .now) async throws -> HealthHistory {
        let excludeOwn = NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: .default()))
        var anchor: HKQueryAnchor?
        var samples: [UUID: HistoricalSleepSample] = [:]
        // No starting date means every accessible historical sleep sample, paged without a fixed year limit.
        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: excludeOwn)],
                anchor: anchor, limit: 1000)
            let page = try await query.result(for: store)
            for deleted in page.deletedObjects { samples.removeValue(forKey: deleted.uuid) }
            for sample in page.addedSamples {
                let stage: HistoricalSleepSample.Stage
                switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                case .asleepUnspecified: stage = .unspecified
                case .asleepCore: stage = .core
                case .asleepDeep: stage = .deep
                case .asleepREM: stage = .rem
                default: continue // Time in bed and awake are never treated as measured sleep.
                }
                samples[sample.uuid] = .init(start: sample.startDate, end: sample.endDate,
                    sourceID: sample.sourceRevision.source.bundleIdentifier, sourceName: sample.sourceRevision.source.name, stage: stage)
            }
            anchor = page.newAnchor
            if page.addedSamples.count + page.deletedObjects.count < 1000 { break }
        }
        var history = HealthHistoryAnalyzer.build(samples: Array(samples.values), now: now, timeZone: .current)
        guard let earliest = samples.values.map(\.start).min() else { return history }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let day = calendar.startOfDay(for: earliest)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [excludeOwn,
            HKQuery.predicateForSamples(withStart: day, end: now, options: .strictStartDate)])
        for identifier in Self.quantities {
            try Task.checkCancellation()
            let query = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate),
                options: [.discreteAverage], anchorDate: day, intervalComponents: DateComponents(day: 1))
            let result = try await query.result(for: store)
            let unit: HKUnit = identifier == .heartRateVariabilitySDNN ? .secondUnit(with: .milli) : .count().unitDivided(by: .minute())
            for sourceIndex in history.sources.indices {
                for nightIndex in history.sources[sourceIndex].nights.indices {
                    let night = history.sources[sourceIndex].nights[nightIndex]
                    let value = result.statistics(for: night.end)?.averageQuantity()?.doubleValue(for: unit)
                    guard let value, value.isFinite, value > 0 else { continue }
                    switch identifier {
                    case .restingHeartRate: history.sources[sourceIndex].nights[nightIndex].restingHeartRate = value
                    case .heartRateVariabilitySDNN: history.sources[sourceIndex].nights[nightIndex].hrv = value
                    default: history.sources[sourceIndex].nights[nightIndex].respiratoryRate = value
                    }
                }
            }
        }
        return history
    }
}
