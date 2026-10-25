import XCTest
@testable import Sleepypod

@MainActor final class PodStageNightTests: XCTestCase {
    func testPodProvenanceAndScoreAreDecodedWithoutAssumingRules() throws {
        let json = #"{"blocks":[],"sleepRecordId":4,"qualityScore":73.2,"stagedBy":{"engine":"model","version":"personal-v2"},"stageView":{"provenance":{"source":"runtime","generation":5,"stageHash":"abc","warning":"Waiting for newer rules"}}}"#
        let stages = try JSONDecoder().decode(PodSleepStages.self, from: Data(json.utf8))
        XCTAssertEqual(stages.score, 73); XCTAssertEqual(stages.sourceLabel, "Pod model · personal-v2")
        XCTAssertEqual(stages.stageView?.provenance.generation, 5)
        let legacy = PodSleepStages(blocks: [], sleepRecordId: 4)
        XCTAssertNil(legacy.score); XCTAssertEqual(legacy.sourceLabel, "Pod · source not reported")
    }
    func testPodBlocksKeepGapsAndMinuteComparisonResolution() {
        let stages = PodSleepStages(blocks: [.init(start: 0, end: 150000, stage: "light"), .init(start: 300000, end: 360000, stage: "deep"), .init(start: 360000, end: 420000, stage: "unknown")], sleepRecordId: 1)
        let epochs = stages.comparisonEpochs
        XCTAssertEqual(epochs.map(\.duration), [60, 60, 30, 60]); XCTAssertTrue(epochs.allSatisfy { $0.heartRate.isNaN })
        let segments = SleepStagesTimelineView.segments(epochs, maxGap: 0)
        XCTAssertEqual(segments.count, 2); XCTAssertEqual(segments.first?.end, Date(timeIntervalSince1970: 150))
        let reference = [WatchComparison.StageSample(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60), stage: .light)]
        XCTAssertEqual(WatchComparison.stageAgreement(epochs: epochs, watch: reference).comparedSeconds, 60)
    }
    func testMismatchedRecordDoesNotDisplayUnrelatedStages() async {
        let model = PodStageNightWorkspace()
        await model.load(recordID: 1, side: .left) { _, _ in .init(blocks: [], sleepRecordId: 2) }
        XCTAssertNil(model.result); XCTAssertNotNil(model.error); XCTAssertFalse(model.loading)
    }
    func testLateNightResponseCannotReplaceNewSelection() async throws {
        let model = PodStageNightWorkspace()
        let gate = StageNightGate()
        let first = Task { await model.load(recordID: 1, side: .left) { _, _ in await gate.wait() } }
        while !(await gate.waiting) { await Task.yield() }
        await model.load(recordID: 2, side: .right) { _, identifier in .init(blocks: [], sleepRecordId: identifier) }
        await gate.release(); await first.value
        XCTAssertEqual(model.result?.sleepRecordId, 2)
    }
}
private actor StageNightGate {
    private var continuation: CheckedContinuation<PodSleepStages, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> PodSleepStages { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: .init(blocks: [], sleepRecordId: 1)); continuation = nil }
}
