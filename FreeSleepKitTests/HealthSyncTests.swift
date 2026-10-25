import Foundation
import HealthKit
import Testing
@testable import FreeSleepKit

@MainActor
struct HealthSyncTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private var range: DateInterval { DateInterval(start: now.addingTimeInterval(-86400), end: now) }
    private var preferences: HealthSyncSettings {
        .init(podID: "my-pod", side: .left, exportHeartRate: false, automatic: true)
    }
    private func record(_ identifier: Int = 1) -> HealthExportRecords.Sleep {
        .init(id: identifier, present_intervals: [[range.start.ISO8601Format(), range.start.addingTimeInterval(3600).ISO8601Format()]])
    }
    private func sample(_ identifier: Int, pod: String = "my-pod", side: BedSide = .left, version: Int = 1) -> HKSample {
        HealthSampleBuilder.presence([record(identifier)], pod: pod, side: side, version: version)[0]
    }

    @Test func syncRejectsDifferentOrChangingPodBeforeWriting() async {
        for identities in [["other-pod"], ["my-pod", "other-pod"]] {
            let store = FakeHealthStore()
            let source = FakeHealthSource(identities: identities, records: [record()])
            do {
                _ = try await HealthSyncEngine(store: store).synchronize(source: source, settings: preferences, range: range, now: now)
                Issue.record("Mismatched Pod identity was accepted")
            } catch { }
            #expect(store.saved.isEmpty && store.deleted.isEmpty)
        }
    }
    @Test func syncRejectsDamagedAndDuplicateExportsBeforeWriting() async {
        for records in [[record(), record()], [.init(id: 1, present_intervals: [], valid: false)],
                        [.init(id: 1, present_intervals: [["invalid", "invalid"]])]] {
            let store = FakeHealthStore()
            let source = FakeHealthSource(records: records)
            do {
                _ = try await HealthSyncEngine(store: store).synchronize(source: source, settings: preferences, range: range, now: now)
                Issue.record("Damaged export was accepted")
            } catch { }
            #expect(store.saved.isEmpty && store.deleted.isEmpty)
        }
    }
    @Test func reconciliationPreservesPartnerAndUnselectedDataAndSavesFirst() async throws {
        let store = FakeHealthStore()
        let heart = HealthSampleBuilder.heart([.init(id: 20, timestamp: range.start.ISO8601Format(), heart_rate: 60)], pod: "my-pod", side: .left, version: 1)[0]
        let outside = HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: now.addingTimeInterval(-40 * 86400), end: now.addingTimeInterval(-39 * 86400), metadata: sample(9).metadata)
        let stale = sample(2)
        store.old = [sample(1), stale, sample(3, side: .right), sample(4, pod: "other-pod"), heart, outside]
        let source = FakeHealthSource(records: [record()])
        let count = try await HealthSyncEngine(store: store).synchronize(source: source, settings: preferences, range: range, now: now)
        #expect(count == 1)
        #expect(store.deleted.map(\.uuid) == [stale.uuid])
        #expect(store.events == ["save", "delete"])
        #expect(await source.heartRequests == 0)
    }
    @Test func failedReplacementBatchNeverDeletesExistingRecords() async {
        let store = FakeHealthStore()
        store.old = [sample(900)]; store.failSaveNumber = 2
        let source = FakeHealthSource(records: (1...101).map { record($0) })
        do {
            _ = try await HealthSyncEngine(store: store).synchronize(source: source, settings: preferences, range: range, now: now)
            Issue.record("Injected save failure was ignored")
        } catch { }
        #expect(store.saved.count == 100)
        #expect(store.deleted.isEmpty)
    }
    @Test func cancellationAfterSavedBatchDoesNotDeleteExistingRecords() async {
        let store = FakeHealthStore()
        store.old = [sample(900)]; store.cancelAfterSave = true
        let source = FakeHealthSource(records: (1...101).map { record($0) })
        let task = Task { try await HealthSyncEngine(store: store).synchronize(source: source, settings: preferences, range: range, now: now) }
        do { _ = try await task.value; Issue.record("Cancelled sync completed") }
        catch { #expect(error is CancellationError) }
        #expect(store.saved.count == 100)
        #expect(store.deleted.isEmpty)
    }
    @Test func reconciliationAdvancesVersionDespiteClockGoingBackwards() async throws {
        let store = FakeHealthStore()
        let futureVersion = Int(now.timeIntervalSince1970 * 1000) + 999_999
        store.old = [sample(1, version: futureVersion)]
        _ = try await HealthSyncEngine(store: store).synchronize(source: FakeHealthSource(records: [record()]), settings: preferences, range: range, now: now)
        #expect(store.saved[0].metadata?[HKMetadataKeySyncVersion] as? Int == futureVersion + 1)
        #expect(store.deleted.isEmpty)
    }
    @Test func emptyConfirmedExportCanRemoveOwnedSamplesAndDeniedWriteCannot() async throws {
        let store = FakeHealthStore()
        store.old = [sample(1)]
        _ = try await HealthSyncEngine(store: store).synchronize(source: FakeHealthSource(), settings: preferences, range: range, now: now)
        #expect(store.deleted.count == 1)
        let denied = FakeHealthStore()
        denied.authorized = false; denied.old = [sample(1)]
        do {
            _ = try await HealthSyncEngine(store: denied).synchronize(source: FakeHealthSource(), settings: preferences, range: range, now: now)
            Issue.record("Missing write authorization was ignored")
        } catch { }
        #expect(denied.deleted.isEmpty)
    }
    @Test func automaticWindowsOverlapAndRespectFirstSyncAndCooldown() throws {
        var settings = preferences
        #expect(HealthSyncPlan.window(settings: settings, trigger: .background, now: now) == nil)
        let first = try #require(HealthSyncPlan.window(settings: settings, trigger: .foreground, now: now))
        #expect(first.duration == 30.0 * 86400)
        settings.lastSuccess = now.addingTimeInterval(-3600)
        let window = try #require(HealthSyncPlan.window(settings: settings, trigger: .background, now: now))
        #expect(window.duration == 2 * 86400 + 3600)
        settings.lastAttempt = now.addingTimeInterval(-100)
        #expect(HealthSyncPlan.window(settings: settings, trigger: .foreground, now: now) == nil)
        let manual = try #require(HealthSyncPlan.window(settings: settings, trigger: .manual, now: now))
        #expect(manual.duration == 30.0 * 86400)
        settings.automatic = false
        #expect(HealthSyncPlan.window(settings: settings, trigger: .background, now: now) == nil)
    }
    @Test func comparisonMergesMultipleSleepSourcesAndPreservesUnknown() {
        let intervals = [DateInterval(start: range.start.addingTimeInterval(-3600), end: range.start.addingTimeInterval(3600)),
                         DateInterval(start: range.start, end: range.start.addingTimeInterval(7200))]
        #expect(HealthComparison.mergedMinutes(intervals, within: range) == 120)
        #expect(HealthComparison.mergedMinutes([], within: range) == nil)
    }
}

@MainActor
private final class FakeHealthStore: HealthSampleStore {
    var authorized = true
    var old: [HKSample] = []
    var saved: [HKSample] = []
    var deleted: [HKSample] = []
    var events: [String] = []
    var failSaveNumber: Int?
    var cancelAfterSave = false
    private var saveCount = 0
    func canWrite(heartRate: Bool) -> Bool { authorized }
    func existing(pod: String, side: BedSide, range: DateInterval, heartRate: Bool) async throws -> [HKSample] { old }
    func save(_ samples: [HKSample]) async throws {
        saveCount += 1
        if saveCount == failSaveNumber { throw PodError.message("Injected save failure") }
        saved += samples; events.append("save")
        if cancelAfterSave { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func delete(_ samples: [HKSample]) async throws { deleted += samples; events.append("delete") }
}

private actor FakeHealthSource: HealthExportSource {
    var identities: [String]
    var records: [HealthExportRecords.Sleep]
    var heartRequests = 0
    init(identities: [String] = ["my-pod"], records: [HealthExportRecords.Sleep] = []) {
        self.identities = identities; self.records = records
    }
    func identity() async throws -> String { identities.count > 1 ? identities.removeFirst() : identities[0] }
    func presence(side: BedSide, range: DateInterval) async throws -> [HealthExportRecords.Sleep] { records }
    func heartRate(side: BedSide, range: DateInterval) async throws -> [HealthExportRecords.Vital] {
        heartRequests += 1
        return []
    }
}
