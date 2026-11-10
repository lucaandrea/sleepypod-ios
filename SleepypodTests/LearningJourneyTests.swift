import XCTest
@testable import Sleepypod

@MainActor final class LearningJourneyTests: XCTestCase {
    private func thermal(side: Side = .left, complete: Int = 13, required: Int = 20, canTrain: Bool = false,
                         generatedAt: Double? = nil, model: ThermalModelStatus.Model? = nil) -> ThermalModelStatus {
        .init(apiVersion: 1, side: side, requiredNights: required, completeNights: complete, feedbackNights: 13,
              datasetHash: String(repeating: "a", count: 64), canTrain: canTrain, excluded: [], model: model, reason: "Collecting", generatedAt: generatedAt)
    }
    private func configure(_ workspace: LearningJourneyWorkspace, side: Side = .left, thermal value: ThermalModelStatus) {
        workspace.configure(side: side, stages: { _ in .init(model: nil, uploadedAt: nil, active: false) }, thermal: { _ in value })
    }
    func testReadinessSeparatesFittingFromControlAndDoesNotInventCoverage() {
        let stages = LearningJourneyStep.stages(inventory: nil, reviewed: nil, required: 5)
        XCTAssertNil(stages.progress); XCTAssertEqual(stages.state, "Needs a current Pod read")
        let step = LearningJourneyStep.temperature(thermal(complete: 20, canTrain: true))
        XCTAssertEqual(step.state, "Ready to review a fit")
        XCTAssertEqual(step.progress?.fraction, 1)
        XCTAssertTrue(step.purpose.contains("does not activate"))
        XCTAssertNil(LearningJourneyStep.temperature(nil).progress)
    }
    func testStoredTemperatureModelsNeedCurrentEvidenceAndPassedComparisons() {
        func model(current: Bool, passed: Bool) -> ThermalModelStatus.Model {
            .init(id: "test", current: current, trainingDates: [], validationDates: [],
                validation: .init(modelMae: 0.3, holdMae: 0.6, averageMae: 0.5, passesFeedbackCheck: passed, reason: "Compared"))
        }
        XCTAssertEqual(LearningJourneyStep.temperature(thermal(model: model(current: false, passed: true))).state, "Recheck changed evidence")
        XCTAssertEqual(LearningJourneyStep.temperature(thermal(model: model(current: true, passed: false))).state, "Comparison needs improvement")
        XCTAssertEqual(LearningJourneyStep.temperature(thermal(model: model(current: true, passed: true))).state, "Research comparison passed")
    }
    func testBaselineVerificationExpiresAndNeverCountsUnloadedRecords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func step(reference: Date?, trained: Date? = nil, loaded: Bool = false) -> LearningJourneyStep {
            .baseline(saved: true, verified: true, referenceEnd: reference, trainedAt: trained ?? now, loaded: loaded, reviewed: 40, required: 40, now: now)
        }
        XCTAssertEqual(step(reference: now).state, "Baseline verified")
        XCTAssertNil(step(reference: now).progress)
        XCTAssertEqual(step(reference: now.addingTimeInterval(-46 * 86400)).state, "Refresh to verify")
        XCTAssertEqual(step(reference: now.addingTimeInterval(60)).state, "Refresh to verify")
        XCTAssertEqual(step(reference: now, trained: now.addingTimeInterval(1)).state, "Refresh to verify")
        XCTAssertEqual(step(reference: now, loaded: true).progress?.reviewed, 40)
    }
    func testReadResultsExpireAndAnOwnerChangeWithdrawsThemImmediately() async {
        let owner = LearningTestOwner()
        let workspace = LearningJourneyWorkspace(currentOwner: { owner.value })
        configure(workspace, thermal: thermal()); await workspace.refresh()
        XCTAssertNotNil(workspace.stages(at: .now)); XCTAssertNotNil(workspace.thermal(at: .now))
        XCTAssertNil(workspace.thermal(at: Date.now.addingTimeInterval(301)))
        XCTAssertNil(workspace.stages(at: Date.now.addingTimeInterval(-61)))
        owner.value = ["different"]
        XCTAssertNil(workspace.thermal(at: .now)); XCTAssertNil(workspace.stages(at: .now))
    }
    func testFailureWithdrawsThePreviousResultButKeepsIndependentSuccess() async {
        let fixture = LearningFixture(value: thermal())
        let workspace = LearningJourneyWorkspace(currentOwner: { ["owner"] })
        workspace.configure(side: .left, stages: { _ in .init(model: nil, uploadedAt: nil, active: false) }, thermal: { _ in try fixture.read() })
        await workspace.refresh(); XCTAssertNotNil(workspace.thermal(at: .now))
        fixture.failing = true
        await workspace.refresh()
        XCTAssertNil(workspace.thermal(at: .now)); XCTAssertNotNil(workspace.thermalError)
        XCTAssertNotNil(workspace.stages(at: .now)); XCTAssertNil(workspace.stageError)
    }
    func testWrongSideInvalidCountsAndExpiredSourceAreRefused() async {
        for value in [thermal(side: .right), thermal(complete: -1), thermal(required: 0), thermal(canTrain: true), thermal(generatedAt: .nan),
                      thermal(generatedAt: Date.now.addingTimeInterval(-301).timeIntervalSince1970 * 1000),
                      thermal(generatedAt: Date.now.addingTimeInterval(61).timeIntervalSince1970 * 1000)] {
            let workspace = LearningJourneyWorkspace(currentOwner: { ["owner"] })
            configure(workspace, thermal: value); await workspace.refresh()
            XCTAssertNil(workspace.thermal(at: .now)); XCTAssertNotNil(workspace.thermalError)
        }
    }
    func testLateOwnerChangedResultCannotCommitOrStartTheSecondRead() async {
        let owner = LearningTestOwner(), gate = LearningTestGate(), value = thermal()
        let fixture = LearningFixture(value: value)
        let workspace = LearningJourneyWorkspace(currentOwner: { owner.value })
        workspace.configure(side: .left, stages: { _ in await gate.wait(); return .init(model: nil, uploadedAt: nil, active: false) }, thermal: { _ in try fixture.read() })
        let task = Task { await workspace.refresh() }
        while !gate.waiting { await Task.yield() }
        owner.value = ["changed"]; gate.release(); await task.value
        XCTAssertNil(workspace.stages(at: .now)); XCTAssertNil(workspace.thermal(at: .now)); XCTAssertEqual(fixture.reads, 0)
    }
    func testCancellationAndInvalidationPreventLateResults() async {
        for invalidate in [false, true] {
            let gate = LearningTestGate(), value = thermal()
            let workspace = LearningJourneyWorkspace(currentOwner: { ["owner"] })
            workspace.configure(side: .left, stages: { _ in await gate.wait(); return .init(model: nil, uploadedAt: nil) }, thermal: { _ in value })
            let task = Task { await workspace.refresh() }
            while !gate.waiting { await Task.yield() }
            if invalidate { workspace.invalidate() } else { task.cancel() }
            gate.release(); await task.value
            XCTAssertNil(workspace.stages(at: .now)); XCTAssertNil(workspace.thermal(at: .now)); XCTAssertFalse(workspace.busy)
        }
    }
    func testPersonalBoundaryDoesNotIssueAnyInventoryRead() async {
        let fixture = LearningFixture(value: thermal())
        let workspace = LearningJourneyWorkspace(currentOwner: { nil })
        workspace.configure(side: .left, stages: nil, thermal: { _ in try fixture.read() })
        await workspace.refresh(); XCTAssertEqual(fixture.reads, 0)
    }
}

@MainActor private final class LearningTestOwner { var value: [String]? = ["owner"] }
@MainActor private final class LearningFixture {
    let value: ThermalModelStatus
    var failing = false
    var reads = 0
    init(value: ThermalModelStatus) { self.value = value }
    func read() throws -> ThermalModelStatus { reads += 1; if failing { throw URLError(.notConnectedToInternet) }; return value }
}
@MainActor private final class LearningTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
