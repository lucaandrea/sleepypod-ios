import HealthKit
import XCTest
@testable import Sleepypod

@MainActor final class NightAnomalyHealthTests: XCTestCase {
    func testNoConsentMeansNoHealthRead() async {
        let probe = NightHealthProbe(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let health = HealthSyncService(store: probe, defaults: defaults)
        do { _ = try await NightAnomalyHealthReader.read(health: health, calendar: .current, now: .now); XCTFail("Expected consent gate") }
        catch { XCTAssertEqual(probe.reads, 0) }
    }

    func testChangedConsentInvalidatesPendingVitalRead() async {
        let probe = NightHealthProbe(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let health = HealthSyncService(store: probe, defaults: defaults)
        health.enabled = true; health.preferences.readVitals = true
        probe.duringRead = { health.preferences.readVitals = false }
        do { _ = try await health.analysisQuantitySamples(.heartRate, start: .distantPast, end: .now); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError); XCTAssertEqual(probe.reads, 1) }
    }

    func testUnrelatedHealthTypesAreNotRead() async {
        let probe = NightHealthProbe(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let health = HealthSyncService(store: probe, defaults: defaults)
        health.enabled = true; health.preferences.readVitals = true
        do { _ = try await health.analysisQuantitySamples(.bloodGlucose, start: .distantPast, end: .now); XCTFail("Expected type restriction") }
        catch { XCTAssertEqual(probe.reads, 0) }
    }

    func testUnderlyingHealthFailureIsNotPresentedAsZeroNights() async {
        let probe = NightHealthProbe(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let health = HealthSyncService(store: probe, defaults: defaults)
        health.enabled = true; health.preferences.readSleep = true; probe.failure = URLError(.cannotOpenFile)
        do { _ = try await NightAnomalyHealthReader.read(health: health, calendar: .current, now: .now); XCTFail("Expected read failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotOpenFile) }
    }
}

@MainActor private final class NightHealthProbe: HealthSyncStore {
    var available = true
    var reads = 0
    var failure: Error?
    var duringRead: (() -> Void)?
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus { .sharingAuthorized }
    func authorize(write: Set<HKSampleType>, read: Set<HKObjectType>) async throws { XCTFail("Must not request permissions implicitly") }
    func save(_ samples: [HKSample]) async throws { XCTFail("No writes") }
    func delete(types: Set<HKSampleType>, deviceID: String, start: Date, end: Date, olderThan version: Int?) async throws { XCTFail("No deletes") }
    func deleteAll(types: Set<HKSampleType>, deviceID: String, olderThan version: Int) async throws { XCTFail("No deletes") }
    func sleepSamples(start: Date, end: Date) async throws -> [HKCategorySample] {
        reads += 1; duringRead?(); if let failure { throw failure }; return []
    }
    func quantitySamples(_ type: HKQuantityTypeIdentifier, start: Date, end: Date) async throws -> [HKQuantitySample] {
        reads += 1; duringRead?(); if let failure { throw failure }; return []
    }
}
