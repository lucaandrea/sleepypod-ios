import XCTest
@testable import Sleepypod

@MainActor final class ComfortOwnerTests: XCTestCase {
    func testSourceGeneratedQualificationActivationAndRecoveryContracts() throws {
        let fixture = try ComfortOwnerExample.load()
        XCTAssertEqual(fixture.statuses.count, 7)
        for status in fixture.statuses.values { try status.validate(side: status.side) }
        for review in fixture.reviews.values { try review.validate(for: .init(side: review.side, purpose: review.purpose, kind: review.kind)) }
        XCTAssertTrue(fixture.statuses["ready"]!.canActivate)
        XCTAssertEqual(fixture.statuses["ready"]!.nights.count, 7)
        XCTAssertTrue(fixture.statuses["active"]!.active)
        XCTAssertFalse(fixture.statuses["retest"]!.active)
        XCTAssertTrue(fixture.statuses["uncertain"]!.application!.uncertain)
        XCTAssertNil(fixture.statuses["resolved"]!.application)
    }
    func testMismatchedSideIdentityClockAndReviewPurposeAreRejected() throws {
        let review = try ComfortOwnerExample.load().reviews["activation"]!
        let request = ComfortOwnerPrepare(side: .left, purpose: .activation, kind: nil)
        for fields: [String: Any] in [["side": "right"], ["expiresAt": review.at + 61_000], ["expiresAt": review.at - 1], ["kind": "cooling"], ["id": "bad-id"]] {
            XCTAssertThrowsError(try ownerReplacing(review, fields).validate(for: request))
        }
        let status = try ComfortOwnerExample.load().statuses["ready"]!
        XCTAssertThrowsError(try status.validate(side: .right))
        XCTAssertThrowsError(try ownerReplacing(status, ["active": true]).validate(side: .left))
        XCTAssertThrowsError(try ownerReplacing(status, ["qualifications": []]).validate(side: .left))
        XCTAssertThrowsError(try ownerReplacing(review, ["snapshot": ["nights": []]]).validate(for: request))
    }
    func testReviewRequiresExplicitConsentAndCannotOutliveItsWindow() async throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let client = try ComfortOwnerProbe(), model = ComfortOwnerWorkspace(now: { clock })
        model.configure(client: client, side: .left); await model.load(); await model.prepare(.activation)
        XCTAssertTrue(model.canConfirm)
        let unconfirmed = await model.confirm(confirmed: false, note: "")
        XCTAssertFalse(unconfirmed)
        clock = clock.addingTimeInterval(61); model.tick(); XCTAssertFalse(model.canConfirm)
        let expired = await model.confirm(confirmed: true, note: "")
        XCTAssertFalse(expired)
        clock = clock.addingTimeInterval(-20); model.tick(); XCTAssertFalse(model.canConfirm)
        let attempts = await client.confirmations; XCTAssertEqual(attempts, 0)
    }
    func testClockRollbackAndDemoCannotConfirmEvidence() async throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let client = try ComfortOwnerProbe(), model = ComfortOwnerWorkspace(now: { clock })
        model.configure(client: client, side: .left); await model.load(); await model.prepare(.activation)
        clock = clock.addingTimeInterval(-1); model.tick(); XCTAssertFalse(model.canConfirm)
        model.configure(client: client, side: .left, demo: true); await model.load(); await model.prepare(.activation)
        XCTAssertNotNil(model.review); XCTAssertFalse(model.canConfirm)
        let result = await model.confirm(confirmed: true, note: "")
        XCTAssertFalse(result); let attempts = await client.confirmations; XCTAssertEqual(attempts, 0)
    }
    func testUnconfirmedWriteRequiresReadbackAndNeverReplays() async throws {
        let client = try ComfortOwnerProbe(), model = ComfortOwnerWorkspace()
        model.configure(client: client, side: .left); await model.load(); await model.prepare(.activation)
        await client.loseConfirmationResponse()
        let first = await model.confirm(confirmed: true, note: "  Attended review  ")
        let second = await model.confirm(confirmed: true, note: "Again")
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertTrue(model.requiresReload); XCTAssertNil(model.review); XCTAssertNil(model.status)
        let attempts = await client.confirmations; XCTAssertEqual(attempts, 1)
        let note = await client.lastNote; XCTAssertEqual(note, "Attended review")
        await model.load(); XCTAssertTrue(model.status?.active == true); XCTAssertFalse(model.requiresReload)
    }
    func testSuccessfulConfirmationRechecksAuthorityAndRetestRevokesIt() async throws {
        let client = try ComfortOwnerProbe(), model = ComfortOwnerWorkspace()
        model.configure(client: client, side: .left); await model.load(); await model.prepare(.activation)
        let result = await model.confirm(confirmed: true, note: "Observed")
        XCTAssertTrue(result); XCTAssertTrue(model.status?.active == true)
        let record = try XCTUnwrap(model.status?.qualifications.first)
        await model.retest(record)
        XCTAssertFalse(model.status!.active); XCTAssertEqual(model.status!.qualifications.first!.outcome, "needs_retest")
        let expected = await client.expectedRetest; XCTAssertEqual(expected, record.id)
    }
    func testConnectionInvalidationDiscardsPreparedEvidenceBeforeConfirmation() async throws {
        let client = try ComfortOwnerProbe(), model = ComfortOwnerWorkspace()
        model.configure(client: client, side: .left); await model.load(); await client.holdPrepare()
        let pending = Task { await model.prepare(.activation) }
        await client.waitHeld(); model.invalidate(); await client.release(); await pending.value
        XCTAssertNil(model.review); XCTAssertNil(model.status); XCTAssertFalse(model.canConfirm)
        let result = await model.confirm(confirmed: true, note: "")
        XCTAssertFalse(result); let attempts = await client.confirmations; XCTAssertEqual(attempts, 0)
    }
    func testPreparationLatencyCannotExtendTheServerReviewLifetime() async throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let client = try ComfortOwnerProbe(), model = ComfortOwnerWorkspace(now: { clock })
        model.configure(client: client, side: .left); await model.load(); await client.holdPrepare()
        let pending = Task { await model.prepare(.activation) }
        await client.waitHeld(); clock = clock.addingTimeInterval(61); await client.release(); await pending.value
        XCTAssertNotNil(model.review); XCTAssertEqual(model.secondsRemaining, 0); XCTAssertFalse(model.canConfirm)
    }
    func testActivePresentationRequiresCurrentGrantAndLegacyConfigurationStaysLocked() throws {
        let source = try PersonalComfortExample.load().status
        let saved = try ownerReplacing(source, ["state": ["config": ["mode": "active"]]])
        XCTAssertFalse(saved.ownerActive); XCTAssertEqual(saved.modeTitle, "Activation not confirmed")
        let active = try ownerReplacing(saved, ["activation": ["current": true]])
        XCTAssertTrue(active.ownerActive); XCTAssertEqual(active.modeTitle, "Personal comfort active")
        XCTAssertThrowsError(try active.state!.config.validate())
        XCTAssertEqual(active.state!.config.editable.mode, "off")
    }
    func testActivationPrepareExplicitlyEncodesNullAndDemoRefusesMutations() async throws {
        let request = ComfortOwnerPrepare(side: .right, purpose: .activation, kind: nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertTrue(object["kind"] is NSNull); XCTAssertEqual(object["side"] as? String, "right")
        let client = ComfortOwnerExampleClient(scenario: "ready")
        let review = try client.prepare(.init(side: .left, purpose: .activation, kind: nil))
        do { _ = try client.confirm(.init(side: .left, id: review.id, confirmed: true, note: "")); XCTFail("Demo confirmed evidence") } catch { }
    }
}

private func ownerReplacing<Value: Codable>(_ value: Value, _ fields: [String: Any]) throws -> Value {
    func merge(_ original: [String: Any], _ update: [String: Any]) -> [String: Any] {
        original.merging(update) { old, new in
            if let old = old as? [String: Any], let new = new as? [String: Any] { return merge(old, new) }; return new
        }
    }
    let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: merge(original, fields)))
}

private actor ComfortOwnerProbe: ComfortOwnerClient {
    let fixture: ComfortOwnerExample
    var name = "ready"
    var confirmations = 0
    var lastNote: String?
    var expectedRetest: String?
    var loseResponse = false, holding = false
    var continuation: CheckedContinuation<Void, Never>?
    init() throws { fixture = try ComfortOwnerExample.load() }
    func loseConfirmationResponse() { loseResponse = true }
    func holdPrepare() { holding = true }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func status(side: Side) -> ComfortOwnerStatus { fixture.statuses[name]! }
    func prepare(_ input: ComfortOwnerPrepare) async -> ComfortOwnerReview {
        if holding { holding = false; await withCheckedContinuation { continuation = $0 } }
        return fixture.reviews[input.kind?.rawValue ?? input.purpose.rawValue]!
    }
    func confirm(_ input: ComfortOwnerConfirm) throws -> ComfortOwnerReceipt {
        confirmations += 1; lastNote = input.note; name = input.id == fixture.reviews["resolution"]?.id ? "resolved" : "active"
        if loseResponse { throw URLError(.timedOut) }; return .init(saved: true)
    }
    func retest(_ input: ComfortOwnerRetest) -> ComfortOwnerReceipt { expectedRetest = input.expectedId; name = "retest"; return .init(saved: true) }
}
