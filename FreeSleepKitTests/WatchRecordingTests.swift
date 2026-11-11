import CryptoKit
import Foundation
import Testing
@testable import FreeSleepKit

struct WatchRecordingTests {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func sample(_ start: String, _ end: String, watch: Bool = true, source: String = "device") -> HistoricalSleepSample {
        .init(start: date(start), end: date(end), sourceID: source, sourceName: "Apple Watch", stage: .core, recordedByWatch: watch)
    }
    @Test func provenanceRequiresDeviceMetadataAndNotAPromisingSourceName() {
        #expect(WatchRecordingSummary.isWatch(productType: "Watch7,12", model: nil, hardwareVersion: nil))
        #expect(WatchRecordingSummary.isWatch(productType: nil, model: "Watch", hardwareVersion: nil))
        #expect(WatchRecordingSummary.isWatch(productType: nil, model: nil, hardwareVersion: "Watch8,1"))
        #expect(!WatchRecordingSummary.isWatch(productType: "iPhone19,1", model: "Apple Watch importer", hardwareVersion: nil))
        let history = HealthHistoryAnalyzer.build(samples: [sample("2026-11-01T07:00:00Z", "2026-11-01T16:00:00Z", watch: false)],
                                                 now: date("2026-11-01T17:00:00Z"), timeZone: zone)
        #expect(history.sources.count == 1); #expect(history.watchNights == [])
    }
    @Test func watchDevicesAreUnionedWithoutDoubleCountingOrThirdPartySleep() {
        let history = HealthHistoryAnalyzer.build(samples: [
            sample("2026-11-01T07:00:00Z", "2026-11-01T12:00:00Z"),
            sample("2026-11-01T10:00:00Z", "2026-11-01T16:00:00Z", source: "other-watch"),
            sample("2026-11-01T06:00:00Z", "2026-11-01T17:00:00Z", watch: false, source: "cover")
        ], now: date("2026-11-01T17:30:00Z"), timeZone: zone)
        #expect(history.sources.count == 3)
        #expect(history.watchNights?.count == 1); #expect(history.watchNights?.first?.asleepMinutes == 540)
        let summary = WatchRecordingSummary(history: history, now: date("2026-11-01T17:30:00Z"))
        #expect(summary.state == .recordsAvailable); #expect(summary.days.count == 7)
        #expect(summary.days.last?.night?.asleepMinutes == 540)
        #expect(summary.days.dropLast().allSatisfy { $0.night == nil })
        #expect(summary.explanation.contains("does not establish"))
    }
    @Test func middayDoesNotTurnThisMorningsNightIntoMissingData() {
        let history = HealthHistoryAnalyzer.build(samples: [sample("2026-11-01T08:00:00Z", "2026-11-01T16:00:00Z")],
                                                 now: date("2026-11-01T17:00:00Z"), timeZone: zone)
        #expect(WatchRecordingSummary(history: history, now: date("2026-11-01T21:00:00Z")).state == .recordsAvailable)
        #expect(WatchRecordingSummary(history: history, now: date("2026-11-02T17:00:00Z")).state == .waitingForRecentRecords)
    }
    @Test func incompleteImportsEmptyResultsAndOldProvenanceRemainDistinct() throws {
        let now = date("2026-11-01T17:00:00Z")
        #expect(WatchRecordingSummary(history: .empty, now: now).state == .notRead)
        let legacy = HealthHistory(importedAt: now, timeZone: zone.identifier, sources: [], ignoredSamples: 0)
        let encoded = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("watchNights"))
        let restored = try JSONDecoder().decode(HealthHistory.self, from: encoded)
        #expect(WatchRecordingSummary(history: restored, now: now).state == .refreshNeeded)
        var empty = legacy; empty.watchNights = []
        #expect(WatchRecordingSummary(history: empty, now: now).state == .noRecordsReturned)
        empty.importedAt = now.addingTimeInterval(3600)
        #expect(WatchRecordingSummary(history: empty, now: now).state == .refreshNeeded)
    }
    @Test func invalidFutureAndNoonCrossingRecordsDoNotCreateExtraSleep() {
        let history = HealthHistoryAnalyzer.build(samples: [
            sample("2026-11-01T19:00:00Z", "2026-11-01T21:00:00Z"),
            sample("2026-11-01T22:00:00Z", "2026-11-01T23:00:00Z"),
            sample("2026-11-01T19:00:00Z", "2026-11-01T18:00:00Z")
        ], now: date("2026-11-01T21:00:00Z"), timeZone: zone)
        #expect(history.ignoredSamples == 2); #expect(history.watchNights?.count == 2)
        #expect(history.watchNights?.map(\.asleepMinutes).reduce(0, +) == 120)
    }
    @Test func morningRefreshAndRetryUseSeparateIntervalsAndRespectOptOut() {
        let morning = date("2026-11-01T16:00:00Z"), evening = date("2026-11-02T02:00:00Z")
        func eligible(_ now: Date, age: Double, attempt: Double? = nil, enabled: Bool = true, requested: Bool = true) -> Bool {
            HealthHistoryRefreshPolicy.shouldRefresh(now: now, importedAt: now.addingTimeInterval(-age * 60),
                lastAttempt: attempt.map { now.addingTimeInterval(-$0 * 60) }, enabled: enabled, requested: requested, timeZone: zone)
        }
        #expect(eligible(morning, age: 30)); #expect(!eligible(morning, age: 29))
        #expect(!eligible(morning, age: 60, attempt: 14)); #expect(eligible(morning, age: 60, attempt: 15))
        #expect(!eligible(evening, age: 359)); #expect(eligible(evening, age: 360))
        #expect(!eligible(morning, age: 500, enabled: false)); #expect(!eligible(morning, age: 500, requested: false))
        #expect(eligible(morning, age: -10, attempt: -10))
    }
}

@MainActor struct WatchHistoryWorkspaceTests {
    private func real(_ body: @MainActor () async throws -> Void) async rethrows {
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            try await PersonalWorkspaceBoundary.$suppliedActive.withValue(false, operation: body)
        }
    }
    private func fixture() throws -> (URL, PersonalIntelligenceStore, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        let store = PersonalIntelligenceStore(directory: directory,
            snapshots: .init(directory: directory, namespace: "watch-test", encryptionKey: { key }))
        let defaults = UserDefaults(suiteName: "watch-\(UUID().uuidString)")!
        defaults.set(true, forKey: "intelligence.healthRequested")
        return (directory, store, defaults)
    }
    private func history() -> HealthHistory {
        .init(importedAt: .now, timeZone: "America/Los_Angeles", sources: [], ignoredSamples: 0, watchNights: [])
    }
    @Test func automaticRefreshDoesNotRequestPermissionAndPersistsReceipt() async throws {
        try await real {
            let (directory, store, defaults) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var readCount = 0, authorizationCount = 0
            let model = IntelligenceWorkspace(defaults: defaults, store: store, readHistory: { readCount += 1; return history() },
                authorizeHistory: { authorizationCount += 1 }, protectedDataAvailable: { true })
            await model.refreshOnActivation(); await model.refreshOnActivation()
            #expect(readCount == 1); #expect(authorizationCount == 0); #expect(model.healthReadError == nil)
            #expect(try store.read().history.watchNights == [])
        }
    }
    @Test func lockedDeviceAndMissingConsentDoNotReadOrAdvanceAttempt() async throws {
        try await real {
            let (directory, store, defaults) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var reads = 0
            let state = WatchHistoryTestState()
            let model = IntelligenceWorkspace(defaults: defaults, store: store, readHistory: { reads += 1; return history() },
                protectedDataAvailable: { state.unlocked })
            await model.refreshOnActivation(); #expect(model.lastHealthAttempt == nil)
            state.unlocked = true; defaults.set(false, forKey: "intelligence.healthRequested")
            await model.refreshOnActivation(); #expect(reads == 0); #expect(model.lastHealthAttempt == nil)
        }
    }
    @Test func failedReadPreservesSavedHistoryAndReportsAndBacksOff() async throws {
        try await real {
            let (directory, store, defaults) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var saved = PersonalIntelligenceArchive(); saved.history = history(); saved.history.importedAt = .distantPast
            saved.reports = [.init(id: UUID(), createdAt: .now, provider: .apple, model: "fixture", source: "example", facts: [], text: "Keep")]
            try store.write(saved)
            var reads = 0
            let model = IntelligenceWorkspace(defaults: defaults, store: store, readHistory: {
                reads += 1; throw PodError.message("Simulated inaccessible Health store")
            }, protectedDataAvailable: { true })
            await model.refreshOnActivation(); await model.refreshOnActivation()
            #expect(reads == 1); #expect(model.healthReadError != nil)
            #expect(model.archive.reports.first?.text == "Keep")
            #expect(try store.read().history == saved.history)
        }
    }
    @Test func lateReadAfterScopeSwitchAndCancellationCannotCommit() async throws {
        for change in ["scope", "cancel"] {
            try await real {
                let (directory, store, defaults) = try fixture()
                defer { try? FileManager.default.removeItem(at: directory) }
                let gate = WatchHistoryGate(), state = WatchHistoryTestState()
                let model = IntelligenceWorkspace(defaults: defaults, store: store, readHistory: {
                    await gate.wait(); return history()
                }, protectedDataAvailable: { true }, historyScope: { state.scope })
                let operation = Task { await model.importHistory(authorize: false) }
                await gate.held()
                if change == "scope" { state.scope = "second" } else { operation.cancel() }
                await gate.release(); await operation.value
                #expect(model.archive.history == .empty); #expect(try store.read().history == .empty)
            }
        }
    }
    @Test func successfulEmptyReadWithdrawsPreviouslyReturnedWatchRecords() async throws {
        try await real {
            let (directory, store, defaults) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var saved = PersonalIntelligenceArchive(); saved.history = history()
            saved.history.watchNights = [.init(id: "past", start: .now.addingTimeInterval(-3600), end: .now,
                                              asleepMinutes: 60)]
            try store.write(saved)
            let model = IntelligenceWorkspace(defaults: defaults, store: store, readHistory: { history() }, protectedDataAvailable: { true })
            await model.importHistory(authorize: false)
            #expect(model.archive.history.watchNights == [])
            #expect(model.message?.contains("No readable sleep records") == true)
        }
    }
    @Test func demoAndPersonalPreparationNeverReadHealth() async throws {
        let (directory, store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var reads = 0
        let model = IntelligenceWorkspace(defaults: defaults, store: store, readHistory: { reads += 1; return history() }, protectedDataAvailable: { true })
        await AppMode.$suppliedBackend.withValue("demo") { await model.importHistory(authorize: false) }
        await PersonalWorkspaceBoundary.$suppliedActive.withValue(true) { await model.importHistory(authorize: false) }
        #expect(reads == 0)
    }
    @Test func unreadableArchiveCannotBeOverwrittenByANewImport() async throws {
        try await real {
            let (directory, store, defaults) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacy = directory.appending(path: "history-and-reports.json")
            let corrupt = Data("unreadable saved archive".utf8)
            try corrupt.write(to: legacy)
            var reads = 0
            let model = IntelligenceWorkspace(defaults: defaults, store: store, readHistory: { reads += 1; return history() }, protectedDataAvailable: { true })
            await model.importHistory(authorize: false)
            #expect(reads == 0); #expect(model.healthReadError?.contains("archive could not be read") == true)
            #expect(try Data(contentsOf: legacy) == corrupt)
        }
    }
}

@MainActor private final class WatchHistoryTestState {
    var unlocked = false
    var scope = "first"
}

private actor WatchHistoryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func held() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
