import XCTest
@testable import Sleepypod

@MainActor final class ArrangementMaintenanceWorkspaceTests: XCTestCase {
    private func approvedReview(_ context: MaintenanceTestContext) throws -> ArrangementReview {
        try PersonalRoutineFixtures.changed(ArrangementFixtures.review()) { object in
            object["reviewId"] = "10000000-0000-4000-8000-000000000099"
            object["state"] = "approved_for_separate_activation"; object["canActivate"] = true; object["canApprove"] = false
            object["createdAt"] = context.now; object["expiresAt"] = context.now + 60_000
            for field in ["self", "partner"] {
                var person = object[field] as? [String: Any] ?? [:]; person["approved"] = true; object[field] = person
            }
        }
    }
    private func setup(_ key: String = "committed") async throws -> (MaintenanceTestContext, MaintenanceTestServer, ArrangementTestServer, ArrangementMaintenanceWorkspace) {
        let context = MaintenanceTestContext(), server = try MaintenanceTestServer(key), reviews = try ArrangementTestServer()
        let model = context.workspace(server, reviews: reviews, session: try await server.session())
        return (context, server, reviews, model)
    }
    func testFreshApprovedReviewCanFollowCompletedCancellation() async throws {
        let (_, server, reviews, _) = try await setup("cancelled")
        let context = MaintenanceTestContext()
        let approved = try approvedReview(context)
        await reviews.setReview(approved)
        let model = context.workspace(server, reviews: reviews, session: try await server.session())
        await model.refresh()
        XCTAssertTrue(model.canStart(approved))
        model.confirmations = ArrangementMaintenanceRequest.Action.activate.confirmations
        await model.activate(approved)
        XCTAssertEqual(model.currentOperation?.state, .committed)
        XCTAssertFalse(model.canStart(approved))
        let posts = await server.posts; XCTAssertEqual(posts, [.activate])
    }
    func testEarlierOrSameReviewCannotRestartCancelledAttempt() async throws {
        for earlier in [true, false] {
            let (context, server, reviews, model) = try await setup("cancelled")
            await model.refresh()
            let prior = try XCTUnwrap(model.currentOperation)
            let approved = try PersonalRoutineFixtures.changed(approvedReview(context)) {
                if earlier { $0["createdAt"] = prior.createdAt - 1 }
                else { $0["reviewId"] = prior.reviewId }
            }
            await reviews.setReview(approved)
            XCTAssertFalse(model.canStart(approved))
            model.confirmations = ArrangementMaintenanceRequest.Action.activate.confirmations
            await model.activate(approved)
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        }
    }
    func testLostActivationWithNoReceiptDoesNotOfferOrSubmitAnotherAttempt() async throws {
        let (context, server, reviews, model) = try await setup("empty")
        let approved = try approvedReview(context)
        await reviews.setReview(approved)
        try await server.configure(failure: .uncertain, beforeWrite: true)
        await model.refresh(); model.confirmations = ArrangementMaintenanceRequest.Action.activate.confirmations
        await model.activate(approved)
        try await server.configure()
        await model.refresh()
        XCTAssertTrue(model.loaded); XCTAssertNil(model.currentOperation); XCTAssertTrue(model.entered)
        XCTAssertFalse(model.canStart(approved))
        model.confirmations = ArrangementMaintenanceRequest.Action.activate.confirmations
        await model.activate(approved)
        let posts = await server.posts; XCTAssertEqual(posts, [.activate])
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
    func testCancellationRechecksUnchangedControlsAfterALongReview() async throws {
        let (context, server, _, model) = try await setup("held")
        await model.refresh(); await model.previewCancellation(); XCTAssertNil(model.cancellation)
        // Change only the simulated generation; there is still no committed side change.
        await server.markRestarted()
        await model.refresh(); await model.previewCancellation(); XCTAssertNotNil(model.cancellation)
        context.now += 300_001; try await server.configure(now: context.now)
        model.confirmations = ArrangementMaintenanceRequest.Action.cancel.confirmations
        await model.cancel()
        XCTAssertEqual(model.currentOperation?.state, .cancelled)
        let posts = await server.posts; XCTAssertEqual(posts, [.cancel])
        let reads = await server.previewReads; XCTAssertEqual(reads, 2)
    }
    func testChangedControlsRequireAnotherReviewWithoutSubmitting() async throws {
        let (_, server, _, model) = try await setup("held")
        await server.markRestarted(); await model.refresh(); await model.previewCancellation()
        await server.configurePreview(digest: String(repeating: "b", count: 64))
        model.confirmations = ArrangementMaintenanceRequest.Action.cancel.confirmations
        await model.cancel()
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        XCTAssertFalse(model.loaded); XCTAssertNil(model.cancellation); XCTAssertTrue(model.confirmations.isEmpty)
    }
    func testRecheckedCancellationStillRejectsStaleAndFutureObservations() async throws {
        for offset in [Int64(-15_001), 1] {
            let (_, server, _, model) = try await setup("held")
            await server.markRestarted(); await model.refresh(); await model.previewCancellation()
            await server.configurePreview(clockOffset: offset)
            model.confirmations = ArrangementMaintenanceRequest.Action.cancel.confirmations
            await model.cancel()
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
            XCTAssertFalse(model.loaded); XCTAssertNil(model.cancellation)
        }
    }
    func testBackgroundDuringCancellationRecheckCannotSubmit() async throws {
        let (_, server, _, model) = try await setup("held")
        await server.markRestarted(); await model.refresh(); await model.previewCancellation()
        model.confirmations = ArrangementMaintenanceRequest.Action.cancel.confirmations
        await server.hold("preview")
        let action = Task { await model.cancel() }
        await server.waitHeld(); model.background(); await server.release(); await action.value
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        XCTAssertNil(model.status); XCTAssertTrue(model.confirmations.isEmpty)
    }
    func testAccountChangeDuringCancellationRecheckCannotSubmit() async throws {
        let (context, server, _, model) = try await setup("held")
        await server.markRestarted(); await model.refresh(); await model.previewCancellation()
        model.confirmations = ArrangementMaintenanceRequest.Action.cancel.confirmations
        await server.hold("preview")
        let action = Task { await model.cancel() }
        await server.waitHeld()
        let other = try PersonalRoutineFixtures.changed(try await server.session()) { $0["accountId"] = UUID().uuidString }
        await server.changeAccount(other); await server.release(); await action.value
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(context.revoked, 1); XCTAssertFalse(model.enabled)
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
