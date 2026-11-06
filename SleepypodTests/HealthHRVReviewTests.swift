import XCTest
@testable import Sleepypod

@MainActor final class HealthHRVReviewTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_900_000)
    private var scope: HealthHRVScope { .init(source: "our.app", deviceID: "pod-left", side: "left", start: start, end: start.addingTimeInterval(86400)) }

    private func entry(_ offset: Int = 0, source: String = "our.app", device: String? = "pod-left", side: String? = "left", metric: String? = nil, provenance: String? = nil) -> HealthHRVEntry {
        let date = start.addingTimeInterval(Double(offset) * 60)
        return .init(id: UUID(), source: source, deviceID: device, side: side, start: date, end: date.addingTimeInterval(60),
                     milliseconds: 42, metric: metric, provenance: provenance)
    }
    private func model(_ probe: HRVReviewProbe) -> HealthHRVReviewWorkspace {
        let result = HealthHRVReviewWorkspace(store: probe)
        result.context = { probe.context }
        return result
    }

    func testReadNeverSelectsOrDeletesAndExcludesOtherSourcesSidesAndVerifiedSDNN() async {
        let probe = HRVReviewProbe()
        let unverified = entry(), legacy = entry(1, side: nil)
        probe.entries = [unverified, legacy, entry(source: "com.apple.watch"), entry(device: "other-left"),
                         entry(device: "pod-right", side: "right"), entry(device: nil), entry(side: "right"),
                         entry(metric: "hrv_sdnn", provenance: "recorded"), entry(1440), entry(-1)]
        let review = model(probe)
        await review.read(scope: scope)
        XCTAssertEqual(Set(review.entries.map(\.id)), [unverified.id, legacy.id])
        XCTAssertEqual(review.retainedSDNN, 1); XCTAssertTrue(review.selected.isEmpty); XCTAssertTrue(probe.removed.isEmpty)
    }

    func testOnlyExactSelectedUnverifiedUUIDsAreRemoved() async {
        let probe = HRVReviewProbe(); probe.entries = [entry(), entry(1)]
        let selected = probe.entries[0], retained = probe.entries[1], review = model(probe)
        await review.read(scope: scope); review.selected = [selected.id]
        await review.removeSelected()
        XCTAssertEqual(probe.removed, [selected.id]); XCTAssertEqual(review.removedCount, 1)
        XCTAssertEqual(review.entries, [retained]); XCTAssertTrue(review.selected.isEmpty); XCTAssertNil(review.error)
    }

    func testMissingSelectedEntriesOrNewProvenanceRequireFreshReviewBeforeDeletion() async {
        for change in ["removed", "verified", "value", "source"] {
            let probe = HRVReviewProbe(); probe.entries = [entry()]
            let review = model(probe); await review.read(scope: scope)
            review.selected = Set(review.entries.map(\.id))
            let old = probe.entries[0]
            if change == "removed" { probe.entries = [] } else {
                probe.entries = [.init(id: old.id, source: change == "source" ? "other" : old.source, deviceID: old.deviceID,
                                       side: old.side, start: old.start, end: old.end, milliseconds: change == "value" ? 500 : old.milliseconds,
                                       metric: change == "verified" ? "hrv_sdnn" : nil,
                                       provenance: change == "verified" ? "recorded" : nil)]
            }
            await review.removeSelected()
            XCTAssertTrue(probe.removed.isEmpty); XCTAssertNotNil(review.error); XCTAssertTrue(review.selected.isEmpty)
        }
    }

    func testSourceSideConsentOrExportChangesStopBeforeDeleteIncludingInsideStoreRecheck() async {
        for timing in ["before", "refresh", "batch"] {
            let probe = HRVReviewProbe(); probe.entries = [entry()]
            let review = model(probe); await review.read(scope: scope); review.selected = Set(review.entries.map(\.id))
            switch timing {
            case "before": probe.context = nil
            case "refresh": probe.afterRead = { probe.context = ["changed"] }
            default: probe.beforeRemove = { probe.context = nil }
            }
            await review.removeSelected()
            XCTAssertTrue(probe.removed.isEmpty); XCTAssertNotNil(review.error)
        }
    }

    func testLaterArrivalsAreNeverSweptAndPartialFailureRequiresNewReview() async {
        let probe = HRVReviewProbe(); probe.entries = (0..<401).map { entry($0) }
        let review = model(probe); await review.read(scope: scope)
        review.selected = Set(review.entries.map(\.id))
        let arrival = entry(500); probe.entries.append(arrival); probe.failBatch = 2
        await review.removeSelected()
        XCTAssertEqual(probe.removed.count, 200); XCTAssertEqual(review.removedCount, 200)
        XCTAssertFalse(probe.removed.contains(arrival.id)); XCTAssertTrue(review.selected.isEmpty); XCTAssertNotNil(review.error)
        review.selected = Set(review.entries.map(\.id))
        await review.removeSelected()
        XCTAssertEqual(probe.removed.count, 200)
    }

    func testForgedSelectionCannotRemoveAnUnreviewedSample() async {
        let probe = HRVReviewProbe(); probe.entries = [entry()]
        let review = model(probe); await review.read(scope: scope); review.selected = [UUID()]
        await review.removeSelected()
        XCTAssertTrue(probe.removed.isEmpty); XCTAssertNotNil(review.error)
    }

    func testInvalidScopePermissionFailureAndChangedReadCannotPublishEntries() async {
        let probe = HRVReviewProbe(); probe.entries = [entry()]
        let review = model(probe)
        await review.read(scope: .init(source: "our.app", deviceID: "pod-left", side: "left", start: start, end: start.addingTimeInterval(100 * 86400)))
        XCTAssertEqual(probe.reads, 0)
        probe.failAuthorization = true; await review.read(scope: scope)
        XCTAssertTrue(review.entries.isEmpty); XCTAssertNotNil(review.error); XCTAssertEqual(probe.reads, 0)
        probe.failAuthorization = false; probe.afterRead = { probe.context = nil }; await review.read(scope: scope)
        XCTAssertTrue(review.entries.isEmpty); XCTAssertNil(review.scope); XCTAssertNotNil(review.error)
    }

    func testClearingDuringReadDiscardsPrivateSnapshotAndPendingSelection() async {
        let probe = HRVReviewProbe(); probe.entries = [entry()]
        let review = model(probe); probe.afterRead = { review.clear() }
        await review.read(scope: scope)
        XCTAssertTrue(review.entries.isEmpty); XCTAssertNil(review.scope); XCTAssertTrue(review.selected.isEmpty)
    }

    func testCancellationCannotDeleteAnything() async {
        let probe = HRVReviewProbe(); probe.entries = [entry()]
        let review = model(probe); await review.read(scope: scope); review.selected = Set(review.entries.map(\.id))
        let task = Task { await review.removeSelected() }; task.cancel(); await task.value
        XCTAssertTrue(probe.removed.isEmpty)
    }
}

@MainActor private final class HRVReviewProbe: HealthHRVReviewStore {
    var entries: [HealthHRVEntry] = []
    var context: [String]? = ["owner", "pod", "left"]
    var removed: [UUID] = []
    var reads = 0
    var batches = 0
    var failBatch: Int?
    var failAuthorization = false
    var afterRead: (() -> Void)?
    var beforeRemove: (() -> Void)?
    func authorize() async throws { if failAuthorization { throw HealthHRVReviewError.permission } }
    func read(_ scope: HealthHRVScope) async throws -> [HealthHRVEntry] {
        reads += 1; let result = entries; afterRead?(); return result
    }
    func remove(_ entries: [HealthHRVEntry], scope: HealthHRVScope, validate: @MainActor () throws -> Void) async throws {
        beforeRemove?(); try validate(); batches += 1
        if batches == failBatch { throw HealthHRVReviewError.permission }
        removed += entries.map(\.id)
        let identifiers = Set(entries.map(\.id)); self.entries.removeAll { identifiers.contains($0.id) }
    }
}
