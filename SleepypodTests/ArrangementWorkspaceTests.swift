import XCTest
@testable import Sleepypod

@MainActor final class ArrangementWorkspaceTests: XCTestCase {
    func testEachPersonMustReadAndIndependentlyConfirmAllThreeFacts() async throws {
        for member in [false, true] {
            let server = try ArrangementTestServer(member: member), context = ArrangementTestContext()
            let model = context.workspace(server, session: try ArrangementFixtures.session(member: member))
            context.confirm(model); await model.approve()
            XCTAssertFalse(model.loaded)
            await model.refresh(); XCTAssertFalse(model.confirmMySide)
            for missing in 0..<3 {
                context.confirm(model)
                if missing == 0 { model.confirmMySide = false }
                if missing == 1 { model.confirmMyRoutine = false }
                if missing == 2 { model.acknowledgeSeparateActivation = false }
                XCTAssertFalse(model.canApprove); await model.approve()
            }
            var posts = await server.posts; XCTAssertTrue(posts.isEmpty)
            context.confirm(model); XCTAssertTrue(model.canApprove); await model.approve()
            XCTAssertTrue(model.review?.person.approved == true); XCTAssertFalse(model.review?.partner.approved == true)
            XCTAssertFalse(model.canApprove); XCTAssertFalse(model.review?.canActivate == true)
            posts = await server.posts; XCTAssertEqual(posts.count, 1)
        }
    }
    func testOwnerProposalRequiresPreservationAndMemberCannotPropose() async throws {
        for member in [false, true] {
            let server = try ArrangementTestServer(member: member, empty: true), context = ArrangementTestContext()
            let model = context.workspace(server, session: try ArrangementFixtures.session(member: member))
            await model.refresh(); await model.propose()
            let empty = await server.posts; XCTAssertTrue(empty.isEmpty)
            model.preserveOperatingWeek = true; model.ownerSide = .left
            XCTAssertFalse(model.preserveOperatingWeek)
            model.preserveOperatingWeek = true; await model.propose()
            let posts = await server.posts; XCTAssertEqual(posts.count, member ? 0 : 1)
            if !member {
                XCTAssertEqual(model.review?.person.week, try ArrangementFixtures.review().person.week)
                let request = try ArrangementRequest.decodeExact(XCTUnwrap(posts.first?.1), action: .propose, session: ArrangementFixtures.session())
                XCTAssertEqual(request.ownerSide, .left); XCTAssertEqual(request.confirmPreserveOperatingOwnerWeek, true)
            }
        }
    }
    func testEveryUncertainMutationNeedsGetAndNeverReplaysAcrossRelaunch() async throws {
        for action in [ArrangementRequest.Action.propose, .approve, .cancel] {
            for failure in [HouseholdFailure.uncertain, .conflict, .invalid, .unavailable] {
                let server = try ArrangementTestServer(empty: action == .propose), context = ArrangementTestContext(), session = try ArrangementFixtures.session()
                let model = context.workspace(server, session: session)
                await model.refresh(); await server.configure(postFailure: failure)
                context.confirm(model); model.preserveOperatingWeek = true
                switch action { case .propose: await model.propose(); case .approve: await model.approve(); case .cancel: await model.cancel() }
                XCTAssertTrue(model.needsReconciliation); XCTAssertFalse(model.loaded)
                context.confirm(model); model.preserveOperatingWeek = true
                await model.approve(); await model.propose(); await model.cancel()
                var posts = await server.posts; XCTAssertEqual(posts.count, 1)
                let relaunched = context.workspace(server, session: session)
                XCTAssertNil(relaunched.review); context.confirm(relaunched); await relaunched.approve()
                await relaunched.refresh(); XCTAssertTrue(relaunched.loaded)
                await model.refresh(); XCTAssertTrue(model.loaded); XCTAssertFalse(model.needsReconciliation)
                XCTAssertFalse(model.confirmMySide); XCTAssertEqual(relaunched.review, model.review)
                posts = await server.posts; XCTAssertEqual(posts.count, 1)
                let reads = await server.reads; XCTAssertGreaterThanOrEqual(reads.filter { $0 == "latest" }.count, 4)
            }
        }
    }
    func testMissingOriginalReviewKeepsUnknownApprovalLockedUntilGetSucceeds() async throws {
        let server = try ArrangementTestServer(), context = ArrangementTestContext()
        let model = context.workspace(server, session: try ArrangementFixtures.session())
        await model.refresh(); context.confirm(model); await server.configure(postFailure: .uncertain); await model.approve()
        let saved = await server.projection; await server.setReview(nil); await model.refresh()
        XCTAssertTrue(model.needsReconciliation); XCTAssertFalse(model.loaded)
        context.confirm(model); await model.approve(); await model.cancel()
        var posts = await server.posts; XCTAssertEqual(posts.count, 1)
        await server.setReview(saved); await model.refresh()
        XCTAssertFalse(model.needsReconciliation); XCTAssertTrue(model.review?.person.approved == true)
        posts = await server.posts; XCTAssertEqual(posts.count, 1)
    }
    func testFreshPreflightDetectsChangedWeekPartnerApprovalAndRevocationStaleness() async throws {
        for change in 0..<3 {
            let server = try ArrangementTestServer(), context = ArrangementTestContext()
            let model = context.workspace(server, session: try ArrangementFixtures.session())
            await model.refresh(); context.confirm(model)
            var updated = try ArrangementFixtures.review()
            if change == 0 {
                updated = try PersonalRoutineFixtures.changed(updated) { object in
                    var person = object["self"] as? [String: Any] ?? [:]; person["week"] = []; object["self"] = person
                }
            } else if change == 1 { updated.partner.approved = true }
            else { updated.state = .stale; updated.canApprove = false }
            await server.setReview(updated); await model.approve()
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertFalse(model.confirmMySide); XCTAssertFalse(model.loaded)
            await model.refresh(); XCTAssertEqual(model.review, updated)
        }
    }
    func testExpiryClockRollbackTerminalStatesAndDisabledCapabilityCannotApprove() async throws {
        for state in [ArrangementReview.State.stale, .expired, .cancelled, .consumed] {
            let server = try ArrangementTestServer(), context = ArrangementTestContext()
            var review = try ArrangementFixtures.review(); review.state = state; review.canApprove = false
            await server.setReview(review)
            let model = context.workspace(server, session: try ArrangementFixtures.session())
            await model.refresh(); context.confirm(model); await model.approve()
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
            XCTAssertEqual(model.canCancel, state == .stale || state == .expired)
        }
        for instant: Int64 in [1_793_311_199_999, 1_793_314_800_000] {
            let server = try ArrangementTestServer(), context = ArrangementTestContext()
            let model = context.workspace(server, session: try ArrangementFixtures.session()); await model.refresh()
            context.now = instant; context.confirm(model); await model.approve()
            XCTAssertFalse(model.canApprove); XCTAssertEqual(model.currentState, .expired)
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        }
        let server = try ArrangementTestServer(enabled: false), context = ArrangementTestContext()
        let model = context.workspace(server, session: try ArrangementFixtures.session(enabled: false))
        await model.refresh(); context.confirm(model); await model.approve()
        XCTAssertFalse(model.enabled); let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testForeignAccountAssignmentAndRevocationHidePrivateReview() async throws {
        for field in ["accountId", "assignmentRevision", "sessionRevision"] {
            let server = try ArrangementTestServer(), context = ArrangementTestContext(), session = try ArrangementFixtures.session()
            let model = context.workspace(server, session: session); await model.refresh(); context.confirm(model)
            let changed = try PersonalRoutineFixtures.changed(session) { $0[field] = field == "accountId" ? UUID().uuidString : 2 }
            await server.setSession(changed); await model.approve()
            XCTAssertNil(model.review); XCTAssertFalse(model.enabled)
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        }
        let server = try ArrangementTestServer(), context = ArrangementTestContext()
        let model = context.workspace(server, session: try ArrangementFixtures.session()); await model.refresh()
        await server.configure(sessionFailure: .authentication); await model.refresh()
        XCTAssertNil(model.review); XCTAssertEqual(context.revocations, 1)
    }
    func testLateReadAndUnsentApprovalCannotCrossInvalidationOrBackgroundBoundary() async throws {
        for boundary in ["account", "background"] {
            let server = try ArrangementTestServer(), context = ArrangementTestContext()
            let model = context.workspace(server, session: try ArrangementFixtures.session()); await model.refresh(); context.confirm(model)
            await server.hold("latest")
            let task = Task { await model.approve() }; await server.waitHeld()
            if boundary == "account" { model.invalidate() } else { model.suspend() }
            XCTAssertNil(model.review); await server.release(); await task.value
            XCTAssertNil(model.review); XCTAssertFalse(model.loaded)
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        }
    }
    func testBothApprovalsStillCannotActivateAndEitherPersonCanCancel() async throws {
        for member in [false, true] {
            let server = try ArrangementTestServer(member: member), context = ArrangementTestContext()
            var review = try ArrangementFixtures.review(member: member); review.partner.approved = true
            await server.setReview(review)
            let model = context.workspace(server, session: try ArrangementFixtures.session(member: member))
            await model.refresh(); context.confirm(model); await model.approve()
            XCTAssertEqual(model.currentState, .approved); XCTAssertFalse(model.review?.canActivate == true)
            await model.cancel(); XCTAssertEqual(model.currentState, .cancelled)
            let posts = await server.posts; XCTAssertEqual(posts.map(\.0), [.approve, .cancel])
        }
    }
    func testParentNeverPersistsReviewBodiesAndSignOutClearsChild() async throws {
        let server = try ArrangementTestServer(), session = try ArrangementFixtures.session(), vault = ArrangementTestVault(session)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!; defaults.set(true, forKey: "household.personalWorkspaceActive")
        let model = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, arrangementClient: { _ in server }, capability: { false }, ownerEndpoint: { nil })
        model.enter(); await model.refresh()
        let child = try XCTUnwrap(model.arrangement); await child.refresh()
        XCTAssertNotNil(child.review)
        let stored = String(decoding: try JSONEncoder().encode(vault.state), as: UTF8.self)
        XCTAssertFalse(stored.contains("reviewId")); XCTAssertFalse(stored.contains("Synthetic example only"))
        child.invalidate(); await model.refresh()
        XCTAssertFalse(model.arrangement === child)
        model.signOut(); XCTAssertNil(model.arrangement); XCTAssertNil(child.review)
    }

    func testPendingSideReviewDoesNotBlockStopThroughSharedParent() async throws {
        let server = try ArrangementTestServer()
        let session = try PersonalRoutineFixtures.changed(ArrangementFixtures.session()) {
            var capabilities = $0["capabilities"] as? [String: Any] ?? [:]; capabilities["personalControls"] = true; $0["capabilities"] = capabilities
        }
        await server.setSession(session)
        let bed = try PersonalRoutineFixtures.changed(PersonalControlFixtures.currentBed()) {
            var scope = $0["scope"] as? [String: Any] ?? [:]
            scope["podId"] = session.podId; scope["householdId"] = session.householdId; scope["sleeperId"] = session.selfSleeperId
            scope["sessionRevision"] = session.sessionRevision; scope["assignmentRevision"] = session.assignmentRevision; $0["scope"] = scope
        }
        let controls = PersonalTestServer(bed: bed, session: session), vault = ArrangementTestVault(session)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, personalClient: { _ in controls },
                                        arrangementClient: { _ in server }, capability: { false }, ownerEndpoint: { nil })
        parent.enter(); await parent.refresh()
        let temperature = try XCTUnwrap(parent.temperature), arrangement = try XCTUnwrap(parent.arrangement)
        await temperature.refresh(); await server.hold("latest")
        let review = Task { await arrangement.refresh() }; await server.waitHeld()
        XCTAssertTrue(arrangement.busy)
        await temperature.submit(.init(kind: "power", powered: false))
        let posts = await controls.posts; XCTAssertEqual(posts.count, 1)
        let action = try JSONDecoder().decode(PersonalControlRequest.self, from: XCTUnwrap(posts.first)).action
        XCTAssertEqual(action.kind, "power"); XCTAssertEqual(action.powered, false)
        await server.release(); await review.value
        let reviewPosts = await server.posts; XCTAssertTrue(reviewPosts.isEmpty)
    }
}
