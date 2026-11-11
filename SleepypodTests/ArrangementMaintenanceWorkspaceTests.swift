import XCTest
@testable import Sleepypod

@MainActor final class ArrangementMaintenanceWorkspaceTests: XCTestCase {
    private func setup(_ key: String = "committed") async throws -> (MaintenanceTestContext, MaintenanceTestServer, ArrangementTestServer, ArrangementMaintenanceWorkspace) {
        let context = MaintenanceTestContext(), server = try MaintenanceTestServer(key), reviews = try ArrangementTestServer()
        let model = context.workspace(server, reviews: reviews, session: try await server.session())
        return (context, server, reviews, model)
    }
    func testInitialSavedTransitionEntersOnceWithoutWriting() async throws {
        let (context, server, _, model) = try await setup()
        await model.refresh(); await model.refresh()
        XCTAssertTrue(model.loaded); XCTAssertTrue(model.entered); XCTAssertEqual(context.entered, 1)
        XCTAssertEqual(model.currentOperation?.state, .committed)
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testLostRestartResponseIsReadBackAndCannotBeRepeated() async throws {
        let (_, server, _, model) = try await setup()
        try await server.configure(failure: .uncertain)
        await model.refresh(); model.confirmations = ArrangementMaintenanceRequest.Action.restart.confirmations
        await model.restart()
        XCTAssertFalse(model.loaded); XCTAssertNotNil(model.error)
        await model.refresh()
        XCTAssertEqual(model.currentOperation?.restart?.state, .submitted)
        model.confirmations = ArrangementMaintenanceRequest.Action.restart.confirmations
        await model.restart()
        let posts = await server.posts; XCTAssertEqual(posts, [.restart])
    }
    func testRecoveryNeedsBothNewGenerationAndAllFreshConfirmations() async throws {
        let (context, server, _, model) = try await setup()
        await model.refresh(); model.confirmations = ArrangementMaintenanceRequest.Action.recover.confirmations
        await model.recover()
        var posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        try await server.configure(key: "readyToRecover")
        await model.refresh(); await model.recover()
        posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        model.confirmations = ArrangementMaintenanceRequest.Action.recover.confirmations
        await model.recover()
        XCTAssertEqual(model.currentOperation?.state, .completed); XCTAssertEqual(context.finished, 0)
        await model.returnToControls()
        XCTAssertEqual(context.finished, 1)
        posts = await server.posts; XCTAssertEqual(posts, [.recover])
    }
    func testCancellationNeedsANewGenerationAndFreshDigestReview() async throws {
        let (context, server, _, model) = try await setup("held")
        await model.refresh(); await model.previewCancellation(); XCTAssertNil(model.cancellation)
        // Change only the simulated generation; there is still no committed side change.
        await server.markRestarted()
        await model.refresh(); await model.previewCancellation(); XCTAssertNotNil(model.cancellation)
        context.now += 60_001; try await server.configure(now: context.now)
        model.confirmations = ArrangementMaintenanceRequest.Action.cancel.confirmations
        await model.cancel()
        let noPosts = await server.posts; XCTAssertTrue(noPosts.isEmpty)
        await model.refresh(); await model.previewCancellation()
        model.confirmations = ArrangementMaintenanceRequest.Action.cancel.confirmations
        await model.cancel()
        XCTAssertEqual(model.currentOperation?.state, .cancelled)
        let posts = await server.posts; XCTAssertEqual(posts, [.cancel])
    }
    func testActivationFollowsItsOwnAssignmentAfterAnUncertainReply() async throws {
        let (context, server, reviews, model) = try await setup("empty")
        let approved = try PersonalRoutineFixtures.changed(ArrangementFixtures.review()) { object in
            object["state"] = "approved_for_separate_activation"; object["canActivate"] = true; object["canApprove"] = false
            object["createdAt"] = context.now - 1000; object["expiresAt"] = context.now + 60_000
            var person = object["self"] as? [String: Any] ?? [:]; person["approved"] = true; object["self"] = person
            var partner = object["partner"] as? [String: Any] ?? [:]; partner["approved"] = true; object["partner"] = partner
        }
        await reviews.setReview(approved); try await server.configure(failure: .uncertain)
        await model.refresh(); model.confirmations = ArrangementMaintenanceRequest.Action.activate.confirmations
        await model.activate(approved)
        XCTAssertFalse(model.loaded); XCTAssertTrue(model.entered)
        await model.refresh()
        XCTAssertTrue(model.loaded); XCTAssertEqual(model.status?.expectedAssignmentRevision, 2)
        XCTAssertEqual(model.currentOperation?.state, .committed); XCTAssertEqual(context.revoked, 0)
        let posts = await server.posts; XCTAssertEqual(posts, [.activate])
    }
    func testBackgroundDuringPreflightClearsConfirmationsAndCannotSendLater() async throws {
        let (_, server, _, model) = try await setup()
        await model.refresh(); model.confirmations = ArrangementMaintenanceRequest.Action.restart.confirmations
        await server.hold("status")
        let action = Task { await model.restart() }
        await server.waitHeld(); model.background(); await server.release(); await action.value
        XCTAssertNil(model.status); XCTAssertTrue(model.confirmations.isEmpty); XCTAssertFalse(model.loaded)
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testChangedOwnerWithdrawsLateDataAndCallsRevocation() async throws {
        let (context, server, _, model) = try await setup()
        await server.hold("status")
        let action = Task { await model.refresh() }
        await server.waitHeld()
        let other = try PersonalRoutineFixtures.changed(try await server.session()) { $0["accountId"] = UUID().uuidString }
        await server.changeAccount(other); await server.release(); await action.value
        XCTAssertEqual(context.revoked, 1); XCTAssertNil(model.status); XCTAssertFalse(model.enabled)
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testTerminalReceiptIsRecheckedBeforeReturningToControls() async throws {
        let (context, server, _, model) = try await setup("completed")
        await model.refresh()
        try await server.configure(key: "committed")
        await model.returnToControls()
        XCTAssertEqual(context.finished, 0); XCTAssertFalse(model.loaded)
    }
}
