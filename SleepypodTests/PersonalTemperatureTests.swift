import XCTest
@testable import Sleepypod

@MainActor final class PersonalTemperatureTests: XCTestCase {
    private func setup(_ name: String = "soloBed", ledger: PersonalTestLedger = .init()) async throws -> (PersonalTemperatureWorkspace, PersonalTestServer, PersonalTestLedger) {
        let bed = try PersonalControlFixtures.bed(name), session = try PersonalControlFixtures.session(for: bed)
        let server = PersonalTestServer(bed: bed, session: session), model = ledger.workspace(server, session: session)
        await model.refresh(); return (model, server, ledger)
    }
    func testSoloShowsMixedRequestedTargetsAndSeparateMeasuredReportedValues() async throws {
        let (model, _, _) = try await setup()
        XCTAssertNil(model.target); XCTAssertTrue(model.readingsCurrent); XCTAssertTrue(model.canAdjust)
        XCTAssertEqual(model.zones.map(\.measuredTemperatureF), [69, 81])
        XCTAssertEqual(model.zones.map(\.reportedTargetF), [70, 82])
        XCTAssertEqual(model.zones.map(\.requestedTargetF), [68, 80])
        XCTAssertEqual(model.bed?.routing.scheduledVibration, [.left])
        XCTAssertEqual(model.bed?.routing.temperature, [.left, .right])
    }
    func testExactRequestIsDurableBeforePostAndAcknowledgmentIsNotReadback() async throws {
        let (model, server, ledger) = try await setup("assignedBed")
        await server.setOnPost { body in await MainActor.run { XCTAssertEqual(ledger.attempts.first?.body, body) } }
        await model.submit(.init(kind: "temperature", temperatureF: 72, holdMinutes: 30))
        let attempt = try XCTUnwrap(ledger.attempts.first)
        XCTAssertEqual(attempt.receipt?.state, "acknowledged"); XCTAssertFalse(model.hasUnresolved)
        XCTAssertEqual(attempt.authorizedZones, [.left]); XCTAssertEqual(model.zones.first?.measuredTemperatureF, 69)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: attempt.body) as? [String: Any])
        XCTAssertNil(body["side"]); XCTAssertEqual(body["requestId"] as? String, attempt.id.uuidString.lowercased())
        let posts = await server.posts; XCTAssertEqual(posts, [attempt.body])
    }
    func testLostResponseSurvivesRelaunchAndOnlyReceiptLookupReconciles() async throws {
        let (model, server, ledger) = try await setup()
        await server.configure(postFailure: .uncertain)
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let original = try XCTUnwrap(ledger.attempts.first)
        XCTAssertTrue(model.hasUnresolved); XCTAssertFalse(model.canAdjust)
        let session = await server.currentSession, restored = ledger.workspace(server, session: session)
        await restored.refresh()
        await restored.submit(.init(kind: "temperature", temperatureF: 71, holdMinutes: 30))
        var posts = await server.posts; XCTAssertEqual(posts.count, 1)
        await restored.reconcile(original.id)
        posts = await server.posts; XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(ledger.attempts.first?.body, original.body)
        let lookups = await server.lookups
        XCTAssertFalse(restored.hasUnresolved); XCTAssertEqual(lookups.count, 1)
    }
    func testMissingReceiptDoesNotMeanNoEffectAndRequiresExplicitExpiredReview() async throws {
        let (model, server, ledger) = try await setup()
        await server.configure(postFailure: .uncertain, missingReceipt: true)
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let attempt = try XCTUnwrap(model.attempts.first)
        await model.reconcile(attempt.id)
        XCTAssertTrue(model.hasUnresolved); XCTAssertFalse(model.canReview(attempt)); XCTAssertFalse(model.canAdjust)
        ledger.date.addTimeInterval(31); ledger.uptime += 31; model.tick()
        XCTAssertTrue(model.canReview(attempt)); model.markReviewed(attempt.id)
        XCTAssertFalse(model.hasUnresolved); XCTAssertNil(model.attempts.first?.receipt)
        let posts = await server.posts; XCTAssertEqual(posts.count, 1)
    }
    func testUncertainCommandsDoNotBlockExplicitStops() async throws {
        let (model, server, _) = try await setup()
        await server.configure(outcome: "unknown")
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        XCTAssertTrue(model.hasUnresolved); XCTAssertTrue(model.canStopPower); XCTAssertTrue(model.canStopVibration)
        await server.configure()
        await model.submit(.init(kind: "power", powered: false))
        await model.submit(.init(kind: "vibration.clear"))
        let posts = await server.posts
        XCTAssertEqual(try posts.map { try JSONDecoder().decode(PersonalControlRequest.self, from: $0).action.kind }, ["temperature", "power", "vibration.clear"])
        XCTAssertTrue(model.hasUnresolved, "A stop receipt does not resolve the earlier uncertain command")
    }
    func testStopRemainsAvailableWhileAnotherSubmissionIsWaiting() async throws {
        let (model, server, _) = try await setup()
        await server.hold("post")
        let command = Task { await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30)) }
        await server.waitHeld()
        XCTAssertFalse(model.canAdjust); XCTAssertTrue(model.canStopPower)
        await model.submit(.init(kind: "power", powered: false))
        await server.release(); await command.value
        let posts = await server.posts; XCTAssertEqual(posts.count, 2)
    }
    func testStopPreemptsOrdinaryActionStillWaitingForPreflight() async throws {
        for stop in [PersonalControlAction(kind: "power", powered: false), .init(kind: "vibration.clear")] {
            let (model, server, ledger) = try await setup()
            await server.hold("bed")
            let command = Task { await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30)) }
            await server.waitHeld(); await model.submit(stop); await server.release(); await command.value
            let posts = await server.posts
            XCTAssertEqual(posts.count, 1)
            XCTAssertEqual(try JSONDecoder().decode(PersonalControlRequest.self, from: XCTUnwrap(posts.first)).action, stop)
            XCTAssertEqual(ledger.attempts.count, 1)
            XCTAssertTrue(model.error?.contains("cancelled before sending") == true)
        }
    }
    func testNewConfigurationNeedsReviewAndCannotReceiveAnOldGesture() async throws {
        let (model, server, _) = try await setup()
        model.edit(fraction: 0.4)
        let changed = try PersonalControlFixtures.changed(try PersonalControlFixtures.bed(), configuration: String(repeating: "c", count: 64))
        await server.setBed(changed); await model.commitDraft()
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertTrue(model.requiresReview); XCTAssertNil(model.draftTarget)
        model.reviewScope(); XCTAssertTrue(model.canAdjust)
    }
    func testAssignmentChangeBetweenGestureAndDispatchRejectsWithoutPost() async throws {
        let (model, server, _) = try await setup("assignedBed")
        let changed = try PersonalControlFixtures.changed(try PersonalControlFixtures.bed("assignedBed"), assignment: 3, side: "right")
        await server.setBed(changed); await server.setSession(try PersonalControlFixtures.session(for: changed))
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertNil(model.bed); XCTAssertFalse(model.canAdjust)
    }
    func testHistoricalReceiptKeepsOriginalScopeAfterSideMove() async throws {
        let (model, server, ledger) = try await setup("assignedBed")
        await server.configure(postFailure: .uncertain)
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let original = try XCTUnwrap(ledger.attempts.first)
        let changed = try PersonalControlFixtures.changed(try PersonalControlFixtures.bed("assignedBed"), assignment: 3, side: "right")
        let session = try PersonalControlFixtures.session(for: changed)
        await server.setBed(changed); await server.setSession(session)
        let restored = ledger.workspace(server, session: session)
        await restored.refresh(); await restored.reconcile(original.id)
        XCTAssertEqual(restored.attempts.first?.receipt?.resolvedZones, [.left])
        XCTAssertEqual(restored.attempts.first?.receipt?.scope.assignmentRevision, 2)
        let posts = await server.posts; XCTAssertEqual(posts.count, 1)
    }
    func testAccountSwitchDuringPreflightDiscardsResponseWithoutDispatch() async throws {
        let (model, server, ledger) = try await setup()
        await server.hold("bed")
        let command = Task { await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30)) }
        await server.waitHeld(); ledger.active = false; model.invalidate()
        await server.release(); await command.value
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertTrue(ledger.attempts.isEmpty); XCTAssertNil(model.bed)
    }
    func testLateAcknowledgmentAfterAccountSwitchCannotPublishOrErasePendingRequest() async throws {
        let (model, server, ledger) = try await setup()
        await server.hold("post")
        let command = Task { await model.submit(.init(kind: "power", powered: true)) }
        await server.waitHeld(); ledger.active = false; model.invalidate()
        await server.release(); await command.value
        XCTAssertNil(ledger.attempts.first?.receipt); XCTAssertTrue(model.attempts.isEmpty); XCTAssertNil(model.bed)
    }
    func testRevocationAndCapabilityRemovalHideControlsWithoutOwnerFallback() async throws {
        let (model, server, _) = try await setup()
        await server.configure(sessionFailure: .authentication)
        await model.submit(.init(kind: "power", powered: true))
        XCTAssertNil(model.bed); XCTAssertFalse(model.canStopPower)
        await server.configure(); await server.setSession(try PersonalControlFixtures.session(for: try PersonalControlFixtures.bed(), controls: false))
        await model.refresh(); XCTAssertNil(model.bed)
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testUnassignedAndDisabledSnapshotsNeverEnableControl() async throws {
        for name in ["unassignedBed", "disabledBed"] {
            let (model, server, _) = try await setup(name)
            XCTAssertFalse(model.available); XCTAssertTrue(model.zones.isEmpty)
            await model.submit(.init(kind: "power", powered: false))
            let posts = await server.posts; XCTAssertTrue(posts.isEmpty)
        }
    }
    func testStorageFailurePreventsTheNetworkEffect() async throws {
        let (model, server, ledger) = try await setup()
        ledger.reject = true
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertFalse(model.canAdjust)
    }
    func testReadingsExpireAndDoNotReturnAfterClockRollbackWithoutANewRead() async throws {
        let (model, _, ledger) = try await setup()
        ledger.uptime -= 1; model.tick(); XCTAssertFalse(model.readingsCurrent)
        ledger.uptime += 2; model.tick(); XCTAssertFalse(model.readingsCurrent)
        XCTAssertTrue(model.zones.allSatisfy { $0.measuredTemperatureF == nil && $0.reportedPowered == nil })
        XCTAssertEqual(model.zones.map(\.requestedTargetF), [68, 80])
    }
    func testReadingsExpireAfterFifteenSecondsAndFutureTimestampsStayUnavailable() async throws {
        let (model, _, ledger) = try await setup()
        ledger.date.addTimeInterval(15); ledger.uptime += 15; model.tick()
        XCTAssertFalse(model.readingsCurrent); XCTAssertNil(model.powered)
        XCTAssertTrue(model.zones.allSatisfy { $0.reportedTargetF == nil })
        let (future, _, futureClock) = try await setup()
        futureClock.date.addTimeInterval(-1); future.tick()
        XCTAssertFalse(future.readingsCurrent)
    }
    func testOlderReceiptLookupCannotReplaceNewerAcknowledgment() async throws {
        let (model, server, _) = try await setup()
        await server.configure(outcome: "executing")
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let attempt = try XCTUnwrap(model.attempts.first)
        await server.hold("receipt")
        let earlier = Task { await model.reconcile(attempt.id) }
        await server.waitHeld()
        await server.setReceipt(PersonalControlFixtures.receipt(attempt.request, zones: attempt.authorizedZones))
        await model.reconcile(attempt.id)
        await server.release(); await earlier.value
        XCTAssertEqual(model.attempts.first?.receipt?.state, "acknowledged")
        XCTAssertFalse(model.hasUnresolved)
    }
    func testReceiptRefreshDoesNotEraseExplicitReviewMadeWhileItWasPending() async throws {
        let (model, server, ledger) = try await setup()
        await server.configure(outcome: "unknown")
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let attempt = try XCTUnwrap(model.attempts.first)
        ledger.date.addTimeInterval(31); ledger.uptime += 31; model.tick()
        await server.hold("receipt")
        let refresh = Task { await model.reconcile(attempt.id) }
        await server.waitHeld(); model.markReviewed(attempt.id)
        await server.release(); await refresh.value
        XCTAssertNotNil(model.attempts.first?.reviewedAt); XCTAssertFalse(model.hasUnresolved)
    }
}
