import XCTest
import HealthKit
@testable import Sleepypod

@MainActor final class NativeHealthSyncTests: XCTestCase {
    private func make(_ store: NativeHealthTestStore, owner: NativeHealthTestOwner = .init()) -> (HealthSyncService, UserDefaults) {
        let defaults = UserDefaults(suiteName: "native-health-\(UUID().uuidString)")!
        defaults.set("right", forKey: "userDefaultSide")
        let service = HealthSyncService(store: store, defaults: defaults, ownerRevision: { owner.value })
        service.enabled = true
        service.preferences.sleep = false; service.preferences.heartRate = false
        service.preferences.hrv = false; service.preferences.respiration = false
        return (service, defaults)
    }
    func testAnalysisHistoryRequiresReadConsentAndPreservesReadFailures() async throws {
        let store = NativeHealthTestStore(), (service, _) = make(store)
        let start = Date(timeIntervalSince1970: 1_700_000_000), end = start.addingTimeInterval(86400)
        service.preferences.readSleep = false
        do { _ = try await service.analysisSleepSamples(start: start, end: end); XCTFail("Read consent is required") } catch {}
        XCTAssertTrue(store.sleepRanges.isEmpty)
        service.preferences.readSleep = true; service.enabled = false
        do { _ = try await service.analysisSleepSamples(start: start, end: end); XCTFail("Health is disabled") } catch {}
        XCTAssertTrue(store.sleepRanges.isEmpty)
        service.enabled = true; store.sleepFailure = URLError(.cannotLoadFromNetwork)
        do { _ = try await service.analysisSleepSamples(start: start, end: end); XCTFail("A failed read must not become empty history") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotLoadFromNetwork) }
        store.sleepFailure = nil
        let values = try await service.analysisSleepSamples(start: start, end: end)
        XCTAssertTrue(values.isEmpty); XCTAssertEqual(store.sleepRanges, [start...end, start...end])
    }
    func testLinkedSideUsesTheSameMigrationAndPrecedenceAsTheNativeProfile() {
        let defaults = UserDefaults(suiteName: "health-side-\(UUID().uuidString)")!
        XCTAssertEqual(HealthSyncService.linkedSide(defaults: defaults), .left)
        defaults.set("right", forKey: "bedSide")
        XCTAssertEqual(HealthSyncService.linkedSide(defaults: defaults), .right)
        defaults.set("left", forKey: "userDefaultSide")
        XCTAssertEqual(HealthSyncService.linkedSide(defaults: defaults), .left)
        defaults.set("invalid", forKey: "userDefaultSide")
        XCTAssertEqual(HealthSyncService.linkedSide(defaults: defaults), .left)
    }
    func testPresenceConsentMigratesFromThePreviouslySelectedSleepChoice() throws {
        for selected in [false, true] {
            let data = Data("{\"sleep\":\(selected),\"heartRate\":false}".utf8)
            let result = try JSONDecoder().decode(HealthSyncService.Preferences.self, from: data)
            XCTAssertEqual(result.presence, selected); XCTAssertEqual(result.sleep, selected)
            XCTAssertFalse(result.heartRate)
        }
        let explicit = try JSONDecoder().decode(HealthSyncService.Preferences.self, from: Data("{\"sleep\":true,\"presence\":false}".utf8))
        XCTAssertFalse(explicit.presence)
    }
    func testReportedPresenceKeepsExitsAndSourceSeparateFromEstimatedStages() throws {
        var record = SleepRecord(id: 1, side: "right", enteredBed: Date(timeIntervalSince1970: 1000), leftBed: Date(timeIntervalSince1970: 5000), timesExitedBed: 1)
        record.presentIntervals = "[[900,1800],[1700,2000],[3500,6000]]"
        var preferences = HealthSyncService.Preferences()
        preferences.sleep = false; preferences.heartRate = false; preferences.hrv = false; preferences.respiration = false
        let samples = HealthSyncService.samples(record: record, epochs: [], podID: "pod", preferences: preferences)
        XCTAssertEqual(samples.map { $0.startDate.timeIntervalSince1970 }, [1000, 3500])
        XCTAssertEqual(samples.map { $0.endDate.timeIntervalSince1970 }, [2000, 5000])
        XCTAssertTrue(samples.allSatisfy { $0.metadata?["sleepypod_source"] as? String == "reported_pod_presence" })
        XCTAssertTrue(samples.allSatisfy { ($0 as? HKCategorySample)?.value == HKCategoryValueSleepAnalysis.inBed.rawValue })
        record.presentIntervals = "broken"
        XCTAssertTrue(HealthSyncService.samples(record: record, epochs: [], podID: "pod", preferences: preferences).isEmpty)
        record.presentIntervals = "[]"
        XCTAssertTrue(HealthSyncService.samples(record: record, epochs: [], podID: "pod", preferences: preferences).isEmpty)
    }
    func testThirtyDayShortcutUsesOnlyPresenceReadsAndReturnsActualSavedCount() async throws {
        let store = NativeHealthTestStore(), (service, _) = make(store)
        let probe = NativeHealthTestProbe(), client = NativeHealthTestClient(probe)
        let count = try await service.syncThirtyDays(api: client, podID: "pod", side: .right, demo: false)
        XCTAssertEqual(count, 2); XCTAssertEqual(store.saved.count, 2); XCTAssertEqual(service.receipts.count, 2)
        XCTAssertEqual(probe.metricReads, 0)
        XCTAssertTrue(probe.requestedSides.allSatisfy { $0 == .right })
        let lower = try XCTUnwrap(probe.ranges.map(\.lowerBound).min()), upper = try XCTUnwrap(probe.ranges.map(\.upperBound).max())
        XCTAssertEqual(upper.timeIntervalSince(lower), 30 * 86400, accuracy: 3601)
        XCTAssertTrue(store.saved.flatMap { $0 }.allSatisfy { $0.device?.localIdentifier == "pod-right" })
        let repeated = try await service.syncThirtyDays(api: client, podID: "pod", side: .right, demo: false)
        XCTAssertEqual(repeated, 0); XCTAssertEqual(store.saved.count, 2)
    }
    func testNoDataReturnsZeroButDemoDisabledAndDeniedConsentCannotReturnSuccess() async throws {
        let store = NativeHealthTestStore(), (service, _) = make(store), probe = NativeHealthTestProbe()
        probe.records = []
        let client = NativeHealthTestClient(probe)
        let empty = try await service.syncThirtyDays(api: client, podID: "pod", side: .right, demo: false)
        XCTAssertEqual(empty, 0)
        for mode in ["demo", "disabled", "denied", "emptyTypes"] {
            service.enabled = mode != "disabled"; store.allowed = mode != "denied"; service.preferences.presence = mode != "emptyTypes"
            let reads = probe.ranges.count
            do { _ = try await service.syncThirtyDays(api: client, podID: "pod", side: .right, demo: mode == "demo"); XCTFail("Expected \(mode) failure") } catch {}
            XCTAssertEqual(probe.ranges.count, reads); XCTAssertTrue(store.saved.isEmpty)
        }
    }
    func testPartialFailureReportsTheActualSavedCountAndNeverSweeps() async throws {
        let store = NativeHealthTestStore(), (service, _) = make(store)
        store.failAt = 2
        do { _ = try await service.syncThirtyDays(api: NativeHealthTestClient(.init()), podID: "pod", side: .right, demo: false); XCTFail("Expected partial failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Saved 1 sample")) }
        XCTAssertEqual(service.lastSyncSampleCount, 1); XCTAssertEqual(service.receipts.count, 1)
        XCTAssertEqual(store.saved.count, 1); XCTAssertEqual(store.sweeps, 0)
    }
    func testOwnerSideAndConsentChangesDuringFetchStopBeforeWrites() async throws {
        for change in ["owner", "side", "consent"] {
            let store = NativeHealthTestStore(), owner = NativeHealthTestOwner(), (service, defaults) = make(store, owner: owner)
            let probe = NativeHealthTestProbe(); probe.hold = true
            let task = Task { try await service.syncThirtyDays(api: NativeHealthTestClient(probe), podID: "pod", side: .right, demo: false) }
            await probe.waitHeld()
            if change == "owner" { owner.value = ["other"] }
            if change == "side" { defaults.set("left", forKey: "userDefaultSide") }
            if change == "consent" { service.preferences.presence = false }
            probe.release()
            do { _ = try await task.value; XCTFail("Changed scope must not succeed") } catch {}
            XCTAssertTrue(store.saved.isEmpty); XCTAssertTrue(store.deleted.isEmpty); XCTAssertTrue(service.receipts.isEmpty)
        }
    }
    func testOwnerChangeDuringSaveKeepsSavedDataWithoutCleanupOrReceiptSuccess() async throws {
        let store = NativeHealthTestStore(), owner = NativeHealthTestOwner(), (service, _) = make(store, owner: owner)
        store.afterSave = { owner.value = ["other"] }
        let complete = await service.rebuild(api: NativeHealthTestClient(.init()), podID: "pod", side: .right, demo: false)
        XCTAssertFalse(complete); XCTAssertEqual(store.saved.count, 1)
        XCTAssertTrue(store.deleted.isEmpty); XCTAssertEqual(store.sweeps, 0); XCTAssertTrue(service.receipts.isEmpty)
    }
    func testConcurrentAndCancelledSyncsCannotWriteOrReportSuccess() async throws {
        let store = NativeHealthTestStore(), (service, _) = make(store), probe = NativeHealthTestProbe()
        probe.hold = true
        let client = NativeHealthTestClient(probe), task = Task { try await service.syncThirtyDays(api: NativeHealthTestClient(probe), podID: "pod", side: .right, demo: false) }
        await probe.waitHeld()
        do { _ = try await service.syncThirtyDays(api: client, podID: "pod", side: .right, demo: false); XCTFail("Busy must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already running")) }
        task.cancel(); probe.release()
        do { _ = try await task.value; XCTFail("Cancelled sync must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(service.isSyncing); XCTAssertTrue(store.saved.isEmpty); XCTAssertTrue(service.failures.isEmpty)
    }
    func testMissingSelectedSDNNKeepsEarlierHRVAndDoesNotClaimCompleteReceipt() async throws {
        let store = NativeHealthTestStore(), (service, _) = make(store), probe = NativeHealthTestProbe()
        service.preferences.hrv = true; probe.provideVitals = true
        do { _ = try await service.syncThirtyDays(api: NativeHealthTestClient(probe), podID: "pod", side: .right, demo: false); XCTFail("Missing selected SDNN is incomplete") } catch {}
        XCTAssertEqual(store.saved.count, 2); XCTAssertEqual(service.lastSyncSampleCount, 2)
        XCTAssertTrue(store.deletedTypes.allSatisfy { !$0.contains(HKQuantityType(.heartRateVariabilitySDNN)) })
        XCTAssertEqual(service.failures.count, 2); XCTAssertTrue(service.receipts.isEmpty); XCTAssertEqual(store.sweeps, 0)
    }
    func testDifferentSideRecordsCannotBeTreatedAsAnEmptySuccessfulRebuild() async {
        let store = NativeHealthTestStore(), (service, _) = make(store), probe = NativeHealthTestProbe()
        for index in probe.records.indices { probe.records[index].side = "left" }
        let result = await service.rebuild(api: NativeHealthTestClient(probe), podID: "pod", side: .right, demo: false)
        XCTAssertFalse(result); XCTAssertEqual(store.sweeps, 0); XCTAssertTrue(store.saved.isEmpty)
    }
    func testMalformedPresenceCannotReplaceEarlierValidHealthData() async throws {
        let store = NativeHealthTestStore(), (service, _) = make(store), probe = NativeHealthTestProbe()
        _ = try await service.syncThirtyDays(api: NativeHealthTestClient(probe), podID: "pod", side: .right, demo: false)
        let receiptCount = service.receipts.count, deleteCount = store.deleted.count, savedCount = store.saved.count
        for index in probe.records.indices { probe.records[index].presentIntervals = "broken"; probe.records[index].timesExitedBed = 1 }
        let result = await service.rebuild(api: NativeHealthTestClient(probe), podID: "pod", side: .right, demo: false)
        XCTAssertFalse(result); XCTAssertEqual(store.saved.count, savedCount); XCTAssertEqual(store.deleted.count, deleteCount)
        XCTAssertEqual(service.receipts.count, receiptCount); XCTAssertEqual(store.sweeps, 0)
    }
}

@MainActor private final class NativeHealthTestOwner { var value = ["owner"] }
@MainActor private final class NativeHealthTestProbe {
    var records: [SleepRecord] = [2, 20, 40].map { days in
        let entered = Date().addingTimeInterval(-Double(days) * 86400)
        return .init(id: days, side: "right", enteredBed: entered, leftBed: entered.addingTimeInterval(3600))
    }
    var ranges: [ClosedRange<Date>] = [], requestedSides: [Side?] = []
    var metricReads = 0, hold = false, provideVitals = false
    private var continuation: CheckedContinuation<Void, Never>?
    func read(side: Side?, start: Date?, end: Date?) async -> [SleepRecord] {
        requestedSides.append(side)
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        guard let start, let end else { return [] }
        ranges.append(start...end)
        return records.filter { $0.enteredBedDate >= start && $0.enteredBedDate < end }
    }
    func metric() { metricReads += 1 }
    func vitals(side: Side?, start: Date?) throws -> [VitalsRecord] {
        metricReads += 1
        guard provideVitals, let start else { throw URLError(.unsupportedURL) }
        return [.init(id: 1, side: (side ?? .right).rawValue, heartRate: 58, hrv: nil, breathingRate: nil, date: start)]
    }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class NativeHealthTestClient: MockAPIClient, @unchecked Sendable {
    let probe: NativeHealthTestProbe
    init(_ probe: NativeHealthTestProbe) { self.probe = probe; super.init() }
    override func getSleepRecords(side: Side?, start: Date?, end: Date?) async throws -> [SleepRecord] { await probe.read(side: side, start: start, end: end) }
    override func getVitals(side: Side?, start: Date?, end: Date?) async throws -> [VitalsRecord] { try await probe.vitals(side: side, start: start) }
    override func getMovement(side: Side?, start: Date?, end: Date?) async throws -> [MovementRecord] { await probe.metric(); throw URLError(.unsupportedURL) }
    override func getCalibrationStatus(side: Side) async throws -> CalibrationStatus { await probe.metric(); throw URLError(.unsupportedURL) }
}
@MainActor private final class NativeHealthTestStore: HealthSyncStore {
    var available = true, allowed = true
    var failAt: Int?, attempts = 0, sweeps = 0
    var saved: [[HKSample]] = [], deleted: [String] = []
    var deletedTypes: [Set<HKSampleType>] = []
    var afterSave: (() -> Void)?
    var sleepRanges: [ClosedRange<Date>] = []
    var sleepFailure: Error?
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus { allowed ? .sharingAuthorized : .sharingDenied }
    func authorize(write: Set<HKSampleType>, read: Set<HKObjectType>) async throws {}
    func save(_ samples: [HKSample]) async throws {
        attempts += 1
        if attempts == failAt { throw URLError(.cannotWriteToFile) }
        saved.append(samples); afterSave?()
    }
    func delete(types: Set<HKSampleType>, deviceID: String, start: Date, end: Date, olderThan version: Int?) async throws { deleted.append(deviceID); deletedTypes.append(types) }
    func deleteAll(types: Set<HKSampleType>, deviceID: String, olderThan version: Int) async throws { sweeps += 1 }
    func sleepSamples(start: Date, end: Date) async throws -> [HKCategorySample] {
        sleepRanges.append(start...end)
        if let sleepFailure { throw sleepFailure }
        return []
    }
    func quantitySamples(_ type: HKQuantityTypeIdentifier, start: Date, end: Date) async throws -> [HKQuantitySample] { [] }
}
