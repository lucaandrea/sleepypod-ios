import Foundation
import HealthKit

@MainActor
struct HealthComparisonReader {
    let store: HKHealthStore
    func read(now: Date = .now) async throws -> HealthComparison {
        let range = DateInterval(start: now.addingTimeInterval(-86400), end: now)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: []),
            NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: .default())),
        ])
        let query = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)], limit: HKObjectQueryNoLimit)
        let sleep = try await query.result(for: store).filter {
            [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
             HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains($0.value)
        }
        var result = HealthComparison(from: range.start, through: range.end,
            asleepMinutes: HealthComparison.mergedMinutes(sleep.map { DateInterval(start: $0.startDate, end: $0.endDate) }, within: range),
            sleepSources: Array(Set(sleep.map { $0.sourceRevision.source.name })).sorted())
        for identifier in [HKQuantityTypeIdentifier.heartRate, .heartRateVariabilitySDNN, .respiratoryRate] {
            try Task.checkCancellation()
            let quantityQuery = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(identifier), predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1)
            guard let sample = try await quantityQuery.result(for: store).first else { continue }
            let unit: HKUnit = identifier == .heartRateVariabilitySDNN ? .secondUnit(with: .milli) : .count().unitDivided(by: .minute())
            let reading = HealthComparison.Quantity(value: sample.quantity.doubleValue(for: unit), source: sample.sourceRevision.source.name, at: sample.startDate)
            switch identifier {
            case .heartRate: result.heartRate = reading
            case .heartRateVariabilitySDNN: result.hrv = reading
            default: result.respiratoryRate = reading
            }
        }
        return result
    }
}
