import XCTest
@testable import Sleepypod

@MainActor final class PersonalRoutineTests: XCTestCase {
    private func setup() throws -> (PersonalRoutineLedger, PersonalRoutineTestServer, PersonalRoutineWorkspace) {
        let review = try PersonalRoutineFixtures.review(), session = try PersonalRoutineFixtures.session()
        let ledger = PersonalRoutineLedger(review: review), server = PersonalRoutineTestServer(review: review, session: session)
        return (ledger, server, ledger.workspace(server, session: session))
    }
    private func confirm(_ model: PersonalRoutineWorkspace) async {
        await model.refresh(); model.confirmReplaceLiveWeek = true; model.acknowledgeCurrentTargetEffect = true
    }
    func testBothConfirmationsAndDurableExactBodyPrecedeOnlyPost() async throws {
        let (ledger, server, model) = try setup()
        await model.refresh(); XCTAssertFalse(model.canPublish)
        model.confirmReplaceLiveWeek = true; XCTAssertFalse(model.canPublish)
        model.acknowledgeCurrentTargetEffect = true; XCTAssertTrue(model.canPublish)
        await server.setOnPost { body in await MainActor.run { XCTAssertEqual(ledger.attempts.first?.body, body) } }
        await model.publish()
        let posts = await server.posts; XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(ledger.attempts.first?.receipt?.scheduler, "refreshed")
        XCTAssertNil(model.review); XCTAssertFalse(model.confirmReplaceLiveWeek); XCTAssertFalse(model.acknowledgeCurrentTargetEffect)
    }
    func testLostResponseAndPostCommitRejectionsRecoverByGetAfterRelaunch() async throws {
        for failure in [HouseholdFailure.uncertain, .conflict, .forbidden] {
            let (ledger, server, model) = try setup()
            await server.configure(postFailure: failure); await confirm(model); await model.publish()
            let attempt = try XCTUnwrap(ledger.attempts.first); XCTAssertNil(attempt.receipt)
            let restored = ledger.workspace(server, session: try PersonalRoutineFixtures.session())
            await confirm(restored); XCTAssertFalse(restored.canPublish)
            await restored.publish(); await restored.reconcile(attempt.id)
            XCTAssertEqual(ledger.attempts.first?.receipt?.state, "saved")
            let posts = await server.posts, lookups = await server.lookups
            XCTAssertEqual(posts.count, 1); XCTAssertEqual(lookups, [attempt.id])
        }
    }
    func testMissingPendingAndUnconfirmedResultsNeverPermitRepublish() async throws {
        for state in ["pending", "unconfirmed", "missing"] {
            let (ledger, server, model) = try setup()
            await server.configure(postFailure: state == "missing" ? .uncertain : nil, scheduler: state == "missing" ? "pending" : state, missing: state == "missing")
            await confirm(model); await model.publish()
            let attempt = try XCTUnwrap(ledger.attempts.first)
            await model.reconcile(attempt.id); await confirm(model)
            XCTAssertTrue(model.hasUnresolved); XCTAssertFalse(model.canPublish)
            await model.publish(); let posts = await server.posts; XCTAssertEqual(posts.count, 1)
            XCTAssertEqual(ledger.attempts.first?.receipt?.scheduler, state == "missing" ? nil : state)
        }
    }
    func testReviewTimeZoneLiveHashAndDraftChangesResetAcknowledgmentsWithoutPost() async throws {
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["timeZone"] = "Europe/Rome" }, { $0["liveRevision"] = String(repeating: "b", count: 64) },
            { $0["reviewRevision"] = String(repeating: "a", count: 64) }, { $0["draftRevision"] = 3 }
        ]
        for edit in edits {
            let (_, server, model) = try setup(); await confirm(model)
            await server.setReview(try PersonalRoutineFixtures.changed(PersonalRoutineFixtures.review(), edit))
            await model.publish()
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
            XCTAssertFalse(model.confirmReplaceLiveWeek); XCTAssertFalse(model.acknowledgeCurrentTargetEffect)
        }
    }
    func testStorageFailureAndPendingDraftPreventAnyPublication() async throws {
        let (ledger, server, model) = try setup(); await confirm(model)
        ledger.ready = false; await model.publish()
        ledger.ready = true; ledger.reject = true; await model.publish()
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertTrue(ledger.attempts.isEmpty)
    }
    func testAccountSwitchDuringPreflightDiscardsPrivateResponseBeforePost() async throws {
        let (ledger, server, model) = try setup(); await confirm(model); await server.hold("review")
        let operation = Task { await model.publish() }
        await server.waitHeld(); ledger.active = false; model.invalidate(); await server.release(); await operation.value
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertNil(model.review); XCTAssertTrue(model.attempts.isEmpty)
    }
    func testLatePostAfterSignOutLeavesDurableUnknownWithoutShowingOldData() async throws {
        let (ledger, server, model) = try setup(); await confirm(model); await server.hold("post")
        let operation = Task { await model.publish() }
        await server.waitHeld(); ledger.active = false; model.invalidate(); await server.release(); await operation.value
        XCTAssertEqual(ledger.attempts.count, 1); XCTAssertNil(ledger.attempts.first?.receipt)
        XCTAssertTrue(model.attempts.isEmpty); XCTAssertNil(model.review)
    }
    func testHistoricalReceiptAfterSideMoveAndDisabledCapabilityDoesNotMoveOldPlan() async throws {
        let (ledger, server, model) = try setup(); await confirm(model); await server.configure(postFailure: .uncertain); await model.publish()
        let attempt = try XCTUnwrap(ledger.attempts.first)
        let moved = try PersonalRoutineFixtures.changed(PersonalRoutineFixtures.session(enabled: false)) {
            $0["assignmentRevision"] = 2; $0["arrangement"] = ["mode": "assigned", "effectiveAt": "2026-10-29T20:00:00Z"]
            $0["self"] = ["displayName": "Fixture Sleeper", "assignment": "right", "zones": ["right"]]
        }
        await server.setSession(moved)
        let restored = ledger.workspace(server, session: moved)
        XCTAssertFalse(restored.enabled); await restored.reconcile(attempt.id)
        XCTAssertEqual(ledger.attempts.first?.receipt?.sourceSide, .left)
        XCTAssertEqual(ledger.attempts.first?.receipt?.scope.assignmentRevision, 1)
        let posts = await server.posts; XCTAssertEqual(posts.count, 1)
    }
    func testAssignmentOrCapabilityChangesDuringPreflightPreventDispatch() async throws {
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["assignmentRevision"] = 2 },
            { var capabilities = $0["capabilities"] as? [String: Any] ?? [:]; capabilities["personalRoutinePublication"] = false; $0["capabilities"] = capabilities }
        ]
        for edit in edits {
            let (_, server, model) = try setup(); await confirm(model)
            await server.setSession(try PersonalRoutineFixtures.changed(PersonalRoutineFixtures.session(), edit)); await model.publish()
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
            XCTAssertFalse(model.canPublish)
        }
    }
    func testRefreshAndLocalDraftChangeAlwaysClearConfirmations() async throws {
        let (_, _, model) = try setup(); await confirm(model); await model.refresh()
        XCTAssertFalse(model.confirmReplaceLiveWeek); XCTAssertFalse(model.acknowledgeCurrentTargetEffect)
        model.confirmReplaceLiveWeek = true; model.discardReview(); XCTAssertNil(model.review); XCTAssertFalse(model.confirmReplaceLiveWeek)
    }
    func testStopPreemptsUnsentPublicationButDoesNotRecallAnAlreadySentRequest() async throws {
        for route in ["review", "post"] {
            let (ledger, server, model) = try setup(); await confirm(model); await server.hold(route)
            let operation = Task { await model.publish() }
            await server.waitHeld(); model.stopUnsentPublication(); await server.release(); await operation.value
            let posts = await server.posts
            XCTAssertEqual(posts.count, route == "review" ? 0 : 1)
            XCTAssertEqual(ledger.attempts.count, route == "review" ? 0 : 1)
            if route == "post" { XCTAssertEqual(ledger.attempts.first?.receipt?.state, "saved") }
            else { XCTAssertTrue(model.error?.contains("cancelled by Stop") == true) }
            XCTAssertFalse(model.confirmReplaceLiveWeek); XCTAssertFalse(model.acknowledgeCurrentTargetEffect)
        }
    }
    func testOlderPendingReceiptCannotDowngradeACompletedPublication() async throws {
        let (ledger, server, model) = try setup(); await confirm(model); await model.publish()
        let attempt = try XCTUnwrap(ledger.attempts.first)
        var pending = PersonalRoutineFixtures.receipt(attempt.request, review: attempt.review); pending.scheduler = "pending"
        await server.setReceipt(pending); await model.reconcile(attempt.id)
        XCTAssertEqual(ledger.attempts.first?.receipt?.scheduler, "refreshed")
    }
}
