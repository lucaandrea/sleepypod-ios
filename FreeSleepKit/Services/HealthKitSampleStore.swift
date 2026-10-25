import Foundation
import HealthKit

@MainActor
final class HealthKitSampleStore: HealthSampleStore {
    let store: HKHealthStore
    init(store: HKHealthStore) { self.store = store }
    private let sleep = HKCategoryType(.sleepAnalysis)
    private let heart = HKQuantityType(.heartRate)

    func canWrite(heartRate: Bool) -> Bool {
        let types: [HKSampleType] = heartRate ? [sleep, heart] : [sleep]
        return types.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
    }
    func existing(pod: String, side: BedSide, range: DateInterval, heartRate: Bool) async throws -> [HKSample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForObjects(withMetadataKey: "FreeSleepPod", allowedValues: [pod]),
            HKQuery.predicateForObjects(withMetadataKey: "FreeSleepSide", allowedValues: [side.rawValue]),
            HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: []),
        ])
        let types: [HKSampleType] = heartRate ? [sleep, heart] : [sleep]
        var samples: [HKSample] = []
        for type in types {
            try Task.checkCancellation()
            let query = HKSampleQueryDescriptor(predicates: [.sample(type: type, predicate: predicate)], sortDescriptors: [], limit: HKObjectQueryNoLimit)
            samples += try await query.result(for: store)
        }
        return samples
    }
    func save(_ samples: [HKSample]) async throws { try await store.save(samples) }
    func delete(_ samples: [HKSample]) async throws { try await store.delete(samples) }
}
