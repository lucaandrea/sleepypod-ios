import Foundation
import HealthKit

@MainActor
struct DaytimeContextReader {
    let store: HKHealthStore
    private static let pageSize = 1000
    private static let maximumSamplesPerType = 40_000
    private static let quantities: [(DaytimeContext.Kind, HKQuantityTypeIdentifier, HKUnit)] = [
        (.exerciseMinutes, .appleExerciseTime, .minute()),
        (.activeEnergyKilocalories, .activeEnergyBurned, .kilocalorie()),
        (.steps, .stepCount, .count()),
        (.sleepingWristCelsius, .appleSleepingWristTemperature, .degreeCelsius())
    ]

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw DaytimeContextError.unavailable }
        let types: Set<HKObjectType> = Set(Self.quantities.map { HKQuantityType($0.1) } + [HKObjectType.workoutType()])
        try await store.requestAuthorization(toShare: [], read: types)
    }

    /// A new bounded snapshot replaces deleted records; no old anchor can preserve revoked observations.
    func read(now: Date = .now) async throws -> DaytimeContext {
        let start = now.addingTimeInterval(-90 * 86_400)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: .default())),
            HKQuery.predicateForSamples(withStart: start, end: now, options: [.strictStartDate, .strictEndDate])
        ])
        var reads: [DaytimeContext.Read] = []
        var observations: [DaytimeContext.Observation] = []
        do {
            let samples = try await load(.workout(predicate))
            observations += samples.map { observation($0, kind: .workout, value: $0.duration / 60, activity: $0.workoutActivityType.rawValue) }
            reads.append(.init(kind: .workout, state: .completed, start: start, end: now))
        } catch is CancellationError { throw CancellationError() }
        catch { reads.append(.init(kind: .workout, state: .unavailable, start: start, end: now)) }
        for (kind, identifier, unit) in Self.quantities {
            try Task.checkCancellation()
            do {
                let samples = try await load(.quantitySample(type: HKQuantityType(identifier), predicate: predicate))
                observations += samples.map { observation($0, kind: kind, value: $0.quantity.doubleValue(for: unit)) }
                reads.append(.init(kind: kind, state: .completed, start: start, end: now))
            } catch is CancellationError { throw CancellationError() }
            catch { reads.append(.init(kind: kind, state: .unavailable, start: start, end: now)) }
        }
        let result = DaytimeContext(importedAt: .now, timeZone: TimeZone.current.identifier, reads: reads, observations: observations)
        try result.validate()
        return result
    }

    private func load<Sample: HKSample>(_ predicate: HKSamplePredicate<Sample>) async throws -> [Sample] {
        var anchor: HKQueryAnchor?
        var samples: [UUID: Sample] = [:]
        var queriedCount = 0
        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(predicates: [predicate], anchor: anchor, limit: Self.pageSize)
            let page = try await query.result(for: store)
            queriedCount += page.addedSamples.count + page.deletedObjects.count
            guard queriedCount <= Self.maximumSamplesPerType else { throw DaytimeContextError.unavailable }
            for deleted in page.deletedObjects { samples.removeValue(forKey: deleted.uuid) }
            for sample in page.addedSamples { samples[sample.uuid] = sample }
            anchor = page.newAnchor
            if page.addedSamples.count + page.deletedObjects.count < Self.pageSize { break }
        }
        return Array(samples.values)
    }

    private func observation(_ sample: HKSample, kind: DaytimeContext.Kind, value: Double, activity: UInt? = nil) -> DaytimeContext.Observation {
        let zone = sample.metadata?[HKMetadataKeyTimeZone] as? String
        return .init(id: sample.uuid, kind: kind,
                     source: .init(identifier: sample.sourceRevision.source.bundleIdentifier,
                                   name: sample.sourceRevision.source.name, device: sample.sourceRevision.productType ?? sample.device?.model,
                                   deviceIdentifier: sample.device?.localIdentifier),
                     start: sample.startDate, end: sample.endDate, value: value, workoutActivity: activity,
                     recordedTimeZone: zone.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 })
    }
}
