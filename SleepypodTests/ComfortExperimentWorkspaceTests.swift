import XCTest
@testable import Sleepypod

actor ComfortExperimentTestServer: ComfortExperimentTransport {
    var account: ComfortExperimentAccess
    var data: [String: Data]
    var detailKey = "saved"
    var stateKey = "status"
    var now: Int64
    var lose = ""
    var rejectReview = false
    var changed = false
    var rejectAfterChange = false
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [(String, Bool)] = []
    init(kind: String = "personal") throws {
        let names = ["library", "savedLibrary", "review", "saved", "status", "controlReview", "admitted", "running", "uncertain", "recovered", "feedbackSaved", "stopped", "closedControl", "cancelled"]
        data = try Dictionary(uniqueKeysWithValues: names.map { ($0, try ComfortExperimentFixtures.data($0, kind: kind)) })
        let saved: ComfortExperimentDetail = try ComfortExperimentFixtures.value("saved", kind: kind)
        now = saved.generatedAt; account = .init(scope: saved.scope, revision: ["fixture"], execution: true)
    }
    func access() async throws -> ComfortExperimentAccess {
        if changed { throw HouseholdFailure.changedIdentity }; return account
    }
    func configure(lose: String = "", rejectReview: Bool = false) { self.lose = lose; self.rejectReview = rejectReview }
    func changeAccount() { changed = true }
    func rejectWithPrivateReasonAfterAccountChange() { rejectAfterChange = true }
    func setNow(_ value: Int64) { now = value }
    func seedUnknown() throws {
        stateKey = "uncertain"; detailKey = "running"
        now = try JSONDecoder().decode(ComfortExperimentExecution.self, from: XCTUnwrap(data["uncertain"])).generatedAt
    }
    func holdNext() { held = true }
    func waitHeld() async throws {
        for _ in 0..<200 { if continuation != nil { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw HouseholdFailure.uncertain
    }
    func release() { continuation?.resume(); continuation = nil }
    func mutations() -> [String] { calls.filter(\.1).map(\.0) }
    func request(_ action: ComfortExperimentRequest) async throws -> Data {
        let payload = try action.payload(); calls.append((payload.path, payload.body != nil))
        if rejectAfterChange {
            changed = true
            throw ComfortExperimentFailure.reason("Private routine details from a revoked account")
        }
        let key: String
        switch action {
        case .library: key = "savedLibrary"
        case .detail: key = detailKey
        case .preview: key = "review"
        case .save: detailKey = "saved"; key = detailKey
        case .execution: key = stateKey
        case .reviewControl:
            if rejectReview { throw ComfortExperimentFailure.reason("Attended qualification is missing.") }
            stateKey = "controlReview"; key = stateKey
        case .confirmControl: stateKey = "admitted"; key = stateKey
        case .stop: detailKey = "stopped"; if stateKey == "admitted" { stateKey = "closedControl" }; key = detailKey
        case .cancelControl: stateKey = "cancelled"; key = stateKey
        case .feedback: detailKey = "feedbackSaved"; key = detailKey
        case .recover: stateKey = "recovered"; key = stateKey
        }
        // Keep source lifecycle clocks intact and advance the synthetic clock when a receipt requires it.
        let raw = try XCTUnwrap(data[key])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        now = max(now, (object["generatedAt"] as? NSNumber)?.int64Value ?? now)
        let response = try ComfortExperimentFixtures.changed(raw) { value in
            value["generatedAt"] = now
            if key == "controlReview" {
                var review = try XCTUnwrap(value["review"] as? [String: Any])
                review["createdAt"] = now; review["expiresAt"] = now + 60_000; value["review"] = review
            }
        }
        if held { held = false; await withCheckedContinuation { continuation = $0 } }
        if !lose.isEmpty && payload.path.hasSuffix(lose) { throw HouseholdFailure.uncertain }
        return response
    }
}

@MainActor final class ComfortExperimentWorkspaceTests: XCTestCase {
    private final class Clock { var date: Date; init(_ milliseconds: Int64) { date = Date(timeIntervalSince1970: Double(milliseconds) / 1000) } }
    private func setup() throws -> (ComfortExperimentWorkspace, ComfortExperimentTestServer, Clock, ComfortExperimentDetail) {
        let detail: ComfortExperimentDetail = try ComfortExperimentFixtures.value("saved")
        let server = try ComfortExperimentTestServer(), clock = Clock(detail.generatedAt)
        let workspace = ComfortExperimentWorkspace(client: server, now: { clock.date })
        return (workspace, server, clock, detail)
    }
    func testOpeningNeverWritesAndReviewRequiresSeparateConfirmation() async throws {
        let (workspace, server, _, detail) = try setup()
        await workspace.open(); XCTAssertNotNil(workspace.library); XCTAssertNil(workspace.error)
        await workspace.select(detail.record.plan.id)
        XCTAssertEqual(workspace.execution?.state, "not_admitted")
        let initial = await server.mutations(); XCTAssertTrue(initial.isEmpty)
        await workspace.reviewControl()
        XCTAssertTrue(workspace.canConfirmControl); XCTAssertEqual(workspace.execution?.review?.sides, [.left, .right])
        await workspace.checkAccess()
        let reviewed = await server.mutations(); XCTAssertEqual(reviewed.count, 1)
        await workspace.confirmControl()
        XCTAssertEqual(workspace.execution?.state, "admitted"); XCTAssertNil(workspace.pending)
    }
    func testReadinessFailureKeepsSavedPlanAndStopReachable() async throws {
        let (workspace, server, _, detail) = try setup()
        await workspace.select(detail.record.plan.id); await server.configure(rejectReview: true)
        await workspace.reviewControl()
        XCTAssertNotNil(workspace.detail); XCTAssertTrue(workspace.canStop)
        XCTAssertEqual(workspace.error, "Attended qualification is missing."); XCTAssertNil(workspace.execution?.review)
    }
    func testBusinessErrorCannotRevealOldAccountContextAfterRevocation() async throws {
        let (workspace, server, _, _) = try setup()
        await server.rejectWithPrivateReasonAfterAccountChange()
        await workspace.preview(.init(firstNightDate: "2026-11-13", variantF: 69))
        XCTAssertTrue(workspace.invalidated); XCTAssertNil(workspace.review)
        XCTAssertFalse(workspace.error?.contains("Private routine details") == true)
    }
    func testReviewExpiryAndBackwardClockNeverSendConfirmation() async throws {
        for backwards in [false, true] {
            let (workspace, server, clock, detail) = try setup()
            await workspace.select(detail.record.plan.id); await workspace.reviewControl()
            clock.date.addTimeInterval(backwards ? -1 : 61)
            await workspace.confirmControl()
            XCTAssertNil(workspace.execution?.review)
            let writes = await server.mutations(); XCTAssertEqual(writes.count, 1)
        }
    }
    func testLostAuthorizationReconcilesWithReadsOnly() async throws {
        let (workspace, server, _, detail) = try setup()
        await workspace.select(detail.record.plan.id); await workspace.reviewControl()
        await server.configure(lose: "/execution/confirm"); await workspace.confirmControl()
        XCTAssertNotNil(workspace.pending); XCTAssertNil(workspace.detail)
        let before = await server.mutations()
        await workspace.open()
        XCTAssertEqual(workspace.execution?.state, "admitted"); XCTAssertNil(workspace.pending)
        let after = await server.mutations(); XCTAssertEqual(after, before)
    }
    func testStopClosesPlanBeforeCancellationAndLostClosureNeedsExplicitFinish() async throws {
        let (workspace, server, clock, detail) = try setup()
        await workspace.select(detail.record.plan.id); await workspace.reviewControl(); await workspace.confirmControl()
        let stopped: ComfortExperimentDetail = try ComfortExperimentFixtures.value("stopped")
        clock.date = Date(timeIntervalSince1970: Double(stopped.generatedAt) / 1000)
        await server.configure(lose: "/stop"); await workspace.stop()
        XCTAssertNotNil(workspace.pending)
        let before = await server.mutations(); XCTAssertEqual(before.last, detail.record.plan.id + "/stop")
        await workspace.reconcile()
        XCTAssertEqual(workspace.detail?.record.status, "stopped"); XCTAssertEqual(workspace.execution?.state, "admitted")
        XCTAssertTrue(workspace.canStop)
        let after = await server.mutations(); XCTAssertEqual(after, before)
        await server.configure(); await workspace.stop()
        XCTAssertEqual(workspace.execution?.state, "revoked"); XCTAssertFalse(workspace.canStop)
        let finished = await server.mutations()
        XCTAssertEqual(Array(finished.suffix(2)), [detail.record.plan.id + "/stop", detail.record.plan.id + "/execution/cancel"])
    }
    func testUnknownFirmwareRecoveryDoesNotResendTemperature() async throws {
        let (workspace, server, clock, detail) = try setup()
        let unknown: ComfortExperimentExecution = try ComfortExperimentFixtures.value("uncertain")
        clock.date = Date(timeIntervalSince1970: Double(unknown.generatedAt) / 1000)
        try await server.seedUnknown(); await workspace.select(detail.record.plan.id)
        let application = try XCTUnwrap(workspace.execution?.applications.first)
        await workspace.recover(application.id)
        XCTAssertEqual(workspace.execution?.state, "revoked")
        XCTAssertEqual(workspace.execution?.applications.first?.outcome, "resolved")
        XCTAssertEqual(workspace.execution?.applications.first?.acknowledgment, "unconfirmed")
        let writes = await server.mutations(); XCTAssertEqual(writes, [detail.record.plan.id + "/execution/recover"])
    }
    func testAccountChangeDuringReplyHidesEverythingAndDoesNotOfferReplay() async throws {
        let (workspace, server, _, detail) = try setup()
        await server.holdNext()
        let task = Task { await workspace.select(detail.record.plan.id) }
        try await server.waitHeld(); await server.changeAccount(); await server.release(); await task.value
        XCTAssertNil(workspace.detail); XCTAssertNil(workspace.execution); XCTAssertTrue(workspace.invalidated)
        let writes = await server.mutations(); XCTAssertTrue(writes.isEmpty)
    }
    func testSuspendHidesContentAndLateRepliesCannotRestoreIt() async throws {
        let (workspace, server, _, detail) = try setup()
        await server.holdNext(); let task = Task { await workspace.select(detail.record.plan.id) }
        try await server.waitHeld(); workspace.suspend(); await server.release(); await task.value
        XCTAssertNil(workspace.detail); XCTAssertNil(workspace.execution); XCTAssertFalse(workspace.busy)
    }
}
