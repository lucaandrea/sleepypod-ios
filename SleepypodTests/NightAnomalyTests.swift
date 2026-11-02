import Foundation
import Testing
@testable import Sleepypod

@Suite("Personal night anomaly learning")
struct NightAnomalyTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { start.addingTimeInterval(70 * 86400) }

    func night(_ index: Int, sleep: Double = 460, source: String = "watch", feature: [String: Double] = [:]) -> NightAnomalyObservation {
        let begin = start.addingTimeInterval(Double(index) * 86400)
        return .init(id: "\(source)-\(index)", sourceID: source, sourceName: source, start: begin, end: begin.addingTimeInterval(8 * 3600),
                     values: ["sleepMinutes": sleep, "midpointMinutes": 180, "awakeFraction": 0.04].merging(feature) { _, new in new },
                     coverage: 1, maximumGapMinutes: 0, sampleCount: 100, evidenceDigest: String(repeating: "a", count: 64))
    }

    @Test func chronologicalCalibrationDoesNotLeakIntoScaling() throws {
        let samples = (0..<40).map { night($0, sleep: $0 < 20 ? 450 : 470) }
        let model = try NightAnomalyModel.fit(samples, now: now)
        #expect(model.trainingNights == 20); #expect(model.calibrationNights == 20)
        #expect(model.centers[0] == 450)
        #expect(model.scales[0] == 15)
        #expect(model.referenceTokens.count == 40)
        #expect(try JSONDecoder().decode(NightAnomalyModel.self, from: JSONEncoder().encode(model)) == model)
    }

    @Test func unchangedNightIsNotAnomalyButNewShiftIs() throws {
        let model = try NightAnomalyModel.fit((0..<40).map { night($0) }, now: now)
        let usual = try model.assess(night(40), now: now)
        let shifted = try model.assess(night(41, sleep: 365, feature: ["midpointMinutes": 360]), now: now)
        #expect(!usual.unusual); #expect(usual.score == 0)
        #expect(shifted.unusual); #expect(shifted.referencePercentile == 1)
        #expect(shifted.differences.first?.feature == "midpointMinutes")
    }

    @Test func rejectsSmallMixedOverlappingAndInvalidTraining() {
        #expect(throws: NightAnomalyModel.Failure.insufficient) { try NightAnomalyModel.fit((0..<39).map { night($0) }, now: now) }
        #expect(throws: NightAnomalyModel.Failure.invalidData) {
            try NightAnomalyModel.fit((0..<40).map { night($0, source: $0 == 10 ? "other-person" : "watch") }, now: now)
        }
        #expect(throws: NightAnomalyModel.Failure.invalidData) { try NightAnomalyModel.fit((0..<40).map { night($0 == 10 ? 9 : $0) }, now: now) }
        #expect(throws: NightAnomalyModel.Failure.invalidData) { try NightAnomalyModel.fit((0..<40).map { night($0, sleep: 200) }, now: now) }
        #expect(throws: NightAnomalyModel.Failure.invalidData) { try NightAnomalyModel.fit((0..<40).map { night($0, feature: ["heartRate": .infinity]) }, now: now) }
    }

    @Test func noCalibrationOrTrainingNightCanBePresentedAsNew() throws {
        let model = try NightAnomalyModel.fit((0..<40).map { night($0) }, now: now)
        for index in [0, 20, 39] {
            #expect(throws: NightAnomalyModel.Failure.referenceNight) { try model.assess(night(index), now: now) }
        }
        #expect(throws: NightAnomalyModel.Failure.changedSource) { try model.assess(night(40, source: "other"), now: now) }
        #expect(throws: NightAnomalyModel.Failure.staleBaseline) { try model.assess(night(90), now: now.addingTimeInterval(30 * 86400)) }
        #expect(throws: NightAnomalyModel.Failure.invalidData) { try model.assess(night(40), now: start) }
    }

    @Test func missingVitalsNeverBecomeZeroOrChangeColumnsUsingCalibration() throws {
        let training = (0..<40).map { night($0, feature: $0 < 20 ? ["heartRate": 60] : [:]) }
        #expect(throws: NightAnomalyModel.Failure.invalidData) { try NightAnomalyModel.fit(training, now: now, includeVitals: true) }
        let reverse = (0..<40).map { night($0, feature: $0 >= 20 ? ["heartRate": 60] : [:]) }
        let model = try NightAnomalyModel.fit(reverse, now: now)
        #expect(!model.features.contains("heartRate"))
        #expect(throws: NightAnomalyModel.Failure.invalidData) { try NightAnomalyModel.fit(reverse, now: now, includeVitals: true) }
        let withVitals = try NightAnomalyModel.fit((0..<40).map { night($0, feature: ["heartRate": 60, "hrvSDNN": 45]) }, now: now, includeVitals: true)
        #expect(withVitals.features.contains("hrvSDNN"))
    }

    @Test func circularTimingKeepsMidnightNeighborsTogether() throws {
        let model = try NightAnomalyModel.fit((0..<40).map { night($0, feature: ["midpointMinutes": $0.isMultiple(of: 2) ? 1435 : 5]) }, now: now)
        let result = try model.assess(night(40, feature: ["midpointMinutes": 0]), now: now)
        #expect(!result.unusual)
        #expect(abs(result.differences.first { $0.feature == "midpointMinutes" }!.scaledDifference) < 1)
    }

    @Test func referenceDeletionChangeAndCorruptArtifactAreRejected() throws {
        let samples = (0..<40).map { night($0) }
        let model = try NightAnomalyModel.fit(samples, now: now)
        #expect(model.referencesMatch(samples + [night(40)]))
        #expect(!model.referencesMatch(Array(samples.dropLast())))
        #expect(!model.referencesMatch(Array(samples.dropLast()) + [night(39, sleep: 450)]))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        json["scales"] = [0, 0, 0]
        let broken = try JSONDecoder().decode(NightAnomalyModel.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: NightAnomalyModel.Failure.corruptModel) { try broken.validate() }
    }
}

@Suite("Complete-night anomaly dataset")
struct NightAnomalyDatasetTests {
    var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return value }
    var start: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 22))! }
    var now: Date { start.addingTimeInterval(2 * 86400) }
    func sample(_ id: String, offset: Double = 0, hours: Double = 8, category: Int = 1, source: String = "eight") -> NightAnomalyDataset.Sample {
        .init(id: id, sourceID: source, sourceName: source, start: start.addingTimeInterval(offset * 3600), end: start.addingTimeInterval((offset + hours) * 3600), category: category)
    }

    @Test func summarySourcesDoNotInventZeroAwakeAndDuplicatesDoNotDoubleSleep() throws {
        let audit = NightAnomalyDataset.build([sample("one"), sample("one"), sample("duplicate")], calendar: calendar, now: now)
        let night = try #require(audit.nights.first)
        #expect(audit.nights.count == 1); #expect(night.values["sleepMinutes"] == 480)
        #expect(night.values["awakeFraction"] == nil); #expect(night.sampleCount == 2)
    }

    @Test func sourcesRemainSeparateAndLocalClockHandlesDST() {
        let audit = NightAnomalyDataset.build([sample("one"), sample("two", source: "watch")], calendar: calendar, now: now)
        #expect(audit.nights.count == 2)
        // Eight elapsed hours through fall-back end at 05:00; elapsed midpoint is 01:00 standard time.
        #expect(audit.nights.allSatisfy { $0.values["midpointMinutes"] == 60 })
    }

    @Test func rejectsFragmentsConflictsInBedAndUnsettledNight() {
        #expect(NightAnomalyDataset.build([sample("short", hours: 3)], calendar: calendar, now: now).nights.isEmpty)
        #expect(NightAnomalyDataset.build([sample("one"), sample("awake", offset: 1, hours: 1, category: 2)], calendar: calendar, now: now).nights.isEmpty)
        #expect(NightAnomalyDataset.build([sample("inBed", category: 0)], calendar: calendar, now: now).nights.isEmpty)
        #expect(NightAnomalyDataset.build([sample("now")], calendar: calendar, now: start.addingTimeInterval(8 * 3600)).nights.isEmpty)
        let separated = [sample("first", hours: 3.5), sample("second", offset: 5, hours: 3.5)]
        #expect(NightAnomalyDataset.build(separated, calendar: calendar, now: now).nights.isEmpty)
    }

    @Test func stageNightCountsOnlyCoveredSleepAndReviewTracksIntervals() throws {
        let samples = [sample("sleep1", hours: 4, category: 3), sample("wake", offset: 4, hours: 0.25, category: 2), sample("sleep2", offset: 4.25, hours: 3.75, category: 4)]
        let first = try #require(NightAnomalyDataset.build(samples, calendar: calendar, now: now).nights.first)
        #expect(first.values["sleepMinutes"] == 465)
        #expect(first.values["awakeFraction"] == 0.03125)
        let changed = [sample("sleep1-new", hours: 4, category: 3)] + samples.dropFirst()
        let second = try #require(NightAnomalyDataset.build(Array(changed), calendar: calendar, now: now).nights.first)
        #expect(first.reviewToken != second.reviewToken)
    }
}

@Suite("Private anomaly model lifecycle", .serialized) @MainActor
struct NightAnomalyStoreTests {
    @Test func recentReviewRequiresConfirmationAndKeepsSourcesSeparate() throws {
        let fixtures = NightAnomalyTests(), store = NightAnomalyStore()
        store.activate(scope: "owner-A")
        let sameSource = (0..<105).map { fixtures.night($0) }.reversed()
        store.accept(.init(nights: Array(sameSource) + [fixtures.night(106, source: "other")]), now: fixtures.now)
        store.selectedSource = "watch"
        let batch = try #require(store.recentReviewBatch())
        #expect(batch.nights.count == 40)
        #expect(Set(batch.nights.map(\.id)) == Set((65..<105).map { "watch-\($0)" }))
        #expect(store.selected.isEmpty); #expect(!store.canTrain); #expect(store.model == nil)
        #expect(store.confirmReview(batch, currentScope: "owner-A"))
        #expect(store.selected.count == 40); #expect(store.canTrain); #expect(store.model == nil)
        #expect(store.reviewed["other-106"] == nil)
    }

    @Test func bulkReviewPreservesEarlierReviewsAndIndividualChanges() throws {
        let fixtures = NightAnomalyTests(), store = NightAnomalyStore()
        store.activate(scope: "owner-A")
        store.accept(.init(nights: (0..<50).map { fixtures.night($0) }), now: fixtures.now)
        store.review(fixtures.night(0), confirmed: true)
        let batch = try #require(store.recentReviewBatch())
        #expect(store.confirmReview(batch, currentScope: "owner-A")); #expect(store.selected.count == 41)
        store.review(fixtures.night(49), confirmed: false)
        #expect(store.selected.count == 40); #expect(store.reviewed["watch-49"] == nil)
        #expect(store.reviewed["watch-0"] != nil)
    }

    @Test func staleBatchCannotApproveChangedOrNewRecordings() throws {
        let fixtures = NightAnomalyTests(), store = NightAnomalyStore()
        store.activate(scope: "owner-A")
        let original = (0..<40).map { fixtures.night($0) }
        store.accept(.init(nights: original), now: fixtures.now)
        let batch = try #require(store.recentReviewBatch())
        store.accept(.init(nights: Array(original.dropLast()) + [fixtures.night(39, sleep: 455)]), now: fixtures.now)
        #expect(!store.confirmReview(batch, currentScope: "owner-A")); #expect(store.selected.isEmpty)
        store.accept(.init(nights: original + [fixtures.night(40)]), now: fixtures.now)
        #expect(!store.confirmReview(batch, currentScope: "owner-A")); #expect(store.selected.isEmpty)
    }

    @Test func changedSourceOrOwnerInvalidatesPendingConfirmation() throws {
        let fixtures = NightAnomalyTests(), store = NightAnomalyStore()
        store.activate(scope: "owner-A")
        let audit = NightAnomalyDataset.Audit(nights: (0..<40).map { fixtures.night($0) } + (0..<40).map { fixtures.night($0, source: "other") })
        store.accept(audit, now: fixtures.now); store.selectedSource = "watch"
        let batch = try #require(store.recentReviewBatch())
        store.selectedSource = "other"
        #expect(!store.confirmReview(batch, currentScope: "owner-A")); #expect(store.reviewed.isEmpty)
        store.selectedSource = "watch"
        #expect(!store.confirmReview(batch, currentScope: "owner-B")); #expect(store.reviewed.isEmpty)
        store.activate(scope: "owner-B"); store.accept(audit, now: fixtures.now); store.selectedSource = "watch"
        #expect(!store.confirmReview(batch, currentScope: "owner-B")); #expect(store.reviewed.isEmpty)
    }

    @Test func bulkReviewNeverFillsMissingNights() {
        let fixtures = NightAnomalyTests(), store = NightAnomalyStore()
        store.activate(scope: "owner-A")
        #expect(store.recentReviewBatch() == nil)
        store.accept(.init(nights: (0..<39).map { fixtures.night($0) } + [fixtures.night(40, source: "other")]), now: fixtures.now)
        store.selectedSource = "watch"
        #expect(store.recentReviewBatch() == nil); #expect(!store.canTrain)
    }

    @Test func trainingRequiresReviewsAndReloadRequiresUnchangedReferences() async throws {
        let fixtures = NightAnomalyTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.json")
        let store = NightAnomalyStore(file: file)
        store.activate(scope: "owner-A")
        let audit = NightAnomalyDataset.Audit(nights: (0..<40).map { fixtures.night($0) })
        store.accept(audit, now: fixtures.now)
        #expect(!store.canTrain)
        let batch = try #require(store.recentReviewBatch())
        #expect(store.confirmReview(batch, currentScope: "owner-A"))
        #expect(store.canTrain)
        await store.train(now: fixtures.now, currentScope: { "owner-A" })
        #expect(store.model != nil); #expect(store.verified); #expect(store.assessment == nil)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let reopened = NightAnomalyStore(file: file)
        reopened.activate(scope: "owner-A")
        #expect(reopened.model != nil); #expect(!reopened.verified)
        reopened.accept(audit, now: fixtures.now); #expect(reopened.verified)
        reopened.accept(.init(nights: Array(audit.nights.dropLast())), now: fixtures.now)
        #expect(!reopened.verified); #expect(reopened.assessment == nil)
        reopened.activate(scope: "owner-B")
        #expect(reopened.model == nil); #expect(reopened.nights.isEmpty)
    }

    @Test func contextChangeBeforePromotionDoesNotSaveModel() async throws {
        let fixtures = NightAnomalyTests(), file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("model.json")
        let store = NightAnomalyStore(file: file)
        store.activate(scope: "original")
        store.accept(.init(nights: (0..<40).map { fixtures.night($0) }), now: fixtures.now)
        for night in store.nights { store.review(night, confirmed: true) }
        var calls = 0
        await store.train(now: fixtures.now, currentScope: { calls += 1; return calls == 1 ? "original" : "changed" })
        #expect(store.model == nil); #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
