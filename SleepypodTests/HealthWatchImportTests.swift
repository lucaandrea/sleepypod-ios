import XCTest
import HealthKit
@testable import Sleepypod

@MainActor final class HealthWatchImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_800_000)
    private let watch = HKDevice(name: "Watch", manufacturer: "Apple", model: "Watch", hardwareVersion: "Watch7,1", firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    private func stage(_ offset: Double, _ duration: Double, _ value: HKCategoryValueSleepAnalysis = .asleepCore, fromWatch: Bool = true) -> HKCategorySample {
        HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: value.rawValue,
            start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + duration), device: fromWatch ? watch : nil, metadata: nil)
    }
    private func quantity(_ identifier: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, offset: Double = -60) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(identifier), quantity: HKQuantity(unit: unit, doubleValue: value),
            start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset), device: watch, metadata: nil)
    }
    func testWatchOnlyMetricsKeepOriginalBoundariesUnitsAndNoSelfReference() {
        let retained = stage(-600, 120)
        let values: [HKSample] = [retained, retained, stage(-300, 60, fromWatch: false), stage(-200, 60, .inBed),
            quantity(.heartRate, 60, .count().unitDivided(by: .minute())),
            quantity(.heartRateVariabilitySDNN, 0.05, .second()), quantity(.respiratoryRate, 0.25, .count().unitDivided(by: .second()))]
        let snapshot = HealthWatchSnapshot.build(samples: values, window: DateInterval(start: now.addingTimeInterval(-1000), end: now))
        XCTAssertEqual(snapshot.stages.count, 1); XCTAssertEqual(snapshot.stages[0].start, Int(now.timeIntervalSince1970) - 600)
        XCTAssertEqual(snapshot.heart.first?.heartRate, 60); XCTAssertEqual(snapshot.hrv.first?.value, 50)
        XCTAssertEqual(snapshot.breathing.first?.value, 15); XCTAssertEqual(snapshot.excluded, 1)
    }
    func testConflictingStagesAndDuplicateSecondVitalsAreExcludedInsteadOfGuessed() {
        let values: [HKSample] = [stage(-600, 300), stage(-400, 200, .asleepDeep), stage(-100, 20),
            quantity(.heartRate, 60, .count().unitDivided(by: .minute())), quantity(.heartRate, 65, .count().unitDivided(by: .minute())),
            stage(60, 60), quantity(.heartRateVariabilitySDNN, 600, .secondUnit(with: .milli), offset: -400)]
        let snapshot = HealthWatchSnapshot.build(samples: values, window: DateInterval(start: now.addingTimeInterval(-1000), end: now))
        XCTAssertEqual(snapshot.stages.count, 1); XCTAssertTrue(snapshot.heart.isEmpty); XCTAssertTrue(snapshot.hrv.isEmpty)
        XCTAssertEqual(snapshot.excluded, 6)
    }
    func testBatchesUseActualControllerContractAndNeverIncludeUnrelatedHealth() throws {
        let snapshot = HealthWatchSnapshot(window: DateInterval(start: now.addingTimeInterval(-1000), end: now),
            stages: [], heart: (0..<2001).map { .init(timestamp: 1_790_000_000 + $0, heartRate: 60) },
            breathing: [.init(timestamp: 1_790_000_000, value: 14)], hrv: [.init(timestamp: 1_790_000_000, value: 40)], excluded: 0)
        let batches = HealthWatchBatch.batches(snapshot, side: .right)
        XCTAssertEqual(batches.map(\.count), [2000, 1, 1, 1])
        XCTAssertEqual(batches.map(\.path), ["reference-vitals", "reference-vitals", "reference-samples", "reference-samples"])
        let data = try JSONEncoder().encode(batches[0])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["side", "source", "samples"])
        XCTAssertEqual(object["source"] as? String, "apple_watch"); XCTAssertEqual(object["side"] as? String, "right")
    }
    func testChangedConsentPreventsReviewedDataFromBeingSent() async {
        let store = WatchImportHealthStore(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("left", forKey: "userDefaultSide")
        store.stages = [HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: Date.now.addingTimeInterval(-600), end: Date.now.addingTimeInterval(-300), device: watch, metadata: nil)]
        let health = HealthSyncService(store: store, defaults: defaults, ownerRevision: { ["same"] }); health.enabled = true
        let writer = WatchImportWriterProbe(), model = HealthWatchImportWorkspace(side: .left, writer: writer)
        await model.prepare(health: health)
        XCTAssertEqual(model.snapshot?.count, 1)
        health.preferences.readSleep = false
        await model.send(health: health)
        let calls = await writer.calls
        XCTAssertEqual(calls, 0); XCTAssertFalse(model.complete); XCTAssertNotNil(model.error)
    }
    func testPartialImportKeepsReceiptsAndCanRetryWithoutChangingSources() async {
        let store = WatchImportHealthStore(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("left", forKey: "userDefaultSide")
        store.stages = [HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: Date.now.addingTimeInterval(-600), end: Date.now.addingTimeInterval(-300), device: watch, metadata: nil)]
        store.quantities = [HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 60),
            start: Date.now.addingTimeInterval(-400), end: Date.now.addingTimeInterval(-400), device: watch, metadata: nil)]
        let health = HealthSyncService(store: store, defaults: defaults, ownerRevision: { ["same"] }); health.enabled = true
        let writer = WatchImportWriterProbe(), model = HealthWatchImportWorkspace(side: .left, writer: writer)
        await writer.fail(on: 2)
        await model.prepare(health: health); await model.send(health: health)
        XCTAssertEqual(model.written, 1); XCTAssertEqual(model.processed, 1); XCTAssertFalse(model.complete)
        XCTAssertNotNil(model.error)
        await writer.fail(on: nil)
        await model.send(health: health)
        XCTAssertTrue(model.complete); XCTAssertNil(model.error); XCTAssertEqual(model.processed, 2)
        let sides = await writer.sides
        XCTAssertTrue(sides.allSatisfy { $0 == .left })
    }
    func testHealthReadIsPagedAndDeniedOrWrongSideCannotImport() async throws {
        let store = WatchImportHealthStore(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("left", forKey: "userDefaultSide")
        let health = HealthSyncService(store: store, defaults: defaults, ownerRevision: { ["same"] }); health.enabled = true
        let result = try await health.watchReferenceSnapshot(side: .left, days: 30, now: now)
        XCTAssertEqual(store.sleepReads, 5); XCTAssertEqual(store.quantityReads, 15); XCTAssertEqual(result.count, 0)
        for side in [Side.right, .left] {
            if side == .left { health.preferences.readSleep = false; health.preferences.readVitals = false }
            do { _ = try await health.watchReferenceSnapshot(side: side, days: 30, now: now); XCTFail("Read should be withheld") } catch {}
        }
        XCTAssertEqual(store.sleepReads, 5)
        health.preferences.readSleep = true; store.failure = URLError(.notConnectedToInternet)
        do { _ = try await health.watchReferenceSnapshot(side: .left, days: 7, now: now); XCTFail("Read errors must surface") } catch {}
    }
}

@MainActor private final class WatchImportHealthStore: HealthSyncStore {
    var available = true
    var sleepReads = 0, quantityReads = 0
    var failure: Error?
    var stages: [HKCategorySample] = []
    var quantities: [HKQuantitySample] = []
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus { .sharingAuthorized }
    func authorize(write: Set<HKSampleType>, read: Set<HKObjectType>) async throws {}
    func save(_ samples: [HKSample]) async throws { XCTFail("This path must not write Health") }
    func delete(types: Set<HKSampleType>, deviceID: String, start: Date, end: Date, olderThan version: Int?) async throws { XCTFail("No deletion") }
    func deleteAll(types: Set<HKSampleType>, deviceID: String, olderThan version: Int) async throws { XCTFail("No deletion") }
    func sleepSamples(start: Date, end: Date) async throws -> [HKCategorySample] { sleepReads += 1; if let failure { throw failure }; return stages }
    func quantitySamples(_ type: HKQuantityTypeIdentifier, start: Date, end: Date) async throws -> [HKQuantitySample] { quantityReads += 1; return quantities.filter { $0.quantityType.identifier == type.rawValue } }
}

private actor WatchImportWriterProbe: HealthWatchReferenceWriting {
    nonisolated let destination = "http://test.invalid"
    var calls = 0
    var sides: [Side] = []
    private var failingCall: Int?
    func fail(on call: Int?) { failingCall = call }
    func write(_ batch: HealthWatchBatch) async throws -> Int {
        calls += 1; sides.append(batch.side)
        if calls == failingCall { throw URLError(.notConnectedToInternet) }
        return batch.count
    }
}
