import HealthKit

@MainActor
protocol HealthHRVReviewStore {
    func authorize() async throws
    func read(_ scope: HealthHRVScope) async throws -> [HealthHRVEntry]
    func remove(_ entries: [HealthHRVEntry], scope: HealthHRVScope, validate: @MainActor () throws -> Void) async throws
}

@MainActor
final class SystemHealthHRVReviewStore: HealthHRVReviewStore {
    private let store = HKHealthStore()
    private let type = HKQuantityType(.heartRateVariabilitySDNN)

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthHRVReviewError.unavailable }
        try await store.requestAuthorization(toShare: [type], read: [type])
        try checkAuthorization()
    }

    func read(_ scope: HealthHRVScope) async throws -> [HealthHRVEntry] {
        try checkAuthorization()
        return try await query(scope: scope).map(Self.entry)
    }

    /// Re-read exact UUIDs and compare every reviewed field before deleting this app's samples.
    func remove(_ entries: [HealthHRVEntry], scope: HealthHRVScope, validate: @MainActor () throws -> Void) async throws {
        try validate()
        try checkAuthorization()
        guard !entries.isEmpty, entries.count <= HealthHRVReviewWorkspace.batchSize,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ scope.contains($0) && !$0.hasRecordedSDNN }) else {
            throw HealthHRVReviewError.selection
        }
        let samples = try await query(scope: scope, identifiers: Set(entries.map(\.id)))
        let actual = samples.map(Self.entry).sorted { $0.id.uuidString < $1.id.uuidString }
        guard actual == entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) else { throw HealthHRVReviewError.changed }
        try Task.checkCancellation()
        try checkAuthorization()
        try validate()
        try await store.delete(samples)
    }

    private func checkAuthorization() throws {
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { throw HealthHRVReviewError.permission }
    }

    private func query(scope: HealthHRVScope, identifiers: Set<UUID>? = nil) async throws -> [HKQuantitySample] {
        guard scope.isValid, scope.source == HKSource.default().bundleIdentifier else { throw HealthHRVReviewError.unavailable }
        var predicates = [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForObjects(withDeviceProperty: HKDevicePropertyKeyLocalIdentifier, allowedValues: [scope.deviceID]),
            HKQuery.predicateForSamples(withStart: scope.start, end: scope.end, options: .strictStartDate)
        ]
        if let identifiers { predicates.append(HKQuery.predicateForObjects(with: identifiers)) }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates))],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)], limit: 100_001)
        let samples = try await descriptor.result(for: store)
        try Task.checkCancellation()
        guard samples.count <= 100_000 else { throw HealthHRVReviewError.tooMany }
        return samples
    }

    private static func entry(_ sample: HKQuantitySample) -> HealthHRVEntry {
        .init(id: sample.uuid, source: sample.sourceRevision.source.bundleIdentifier, deviceID: sample.device?.localIdentifier,
              side: sample.metadata?["sleepypod_side"] as? String, start: sample.startDate, end: sample.endDate,
              milliseconds: sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
              metric: sample.metadata?["sleepypod_hrv_metric"] as? String,
              provenance: sample.metadata?["sleepypod_hrv_provenance"] as? String)
    }
}
