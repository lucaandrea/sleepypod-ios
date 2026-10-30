import XCTest
@testable import Sleepypod

final class PersonalRoutineContractTests: XCTestCase {
    func testFrozenReviewRequestAndAllReceiptStatesPreserveCustomAlarm() throws {
        let review = try PersonalRoutineFixtures.review(), session = try PersonalRoutineFixtures.session()
        try review.validate(for: session)
        let request: PersonalRoutineRequest = try PersonalRoutineFixtures.decode("publishRequest")
        let attempt = PersonalRoutineAttempt(request: request, body: try JSONEncoder().encode(request), review: review)
        try attempt.validate()
        for key in ["saved", "schedulerPending", "schedulerUnconfirmed"] {
            let receipt: PersonalRoutineReceipt = try PersonalRoutineFixtures.decode(key)
            try receipt.validate(for: attempt)
            XCTAssertEqual(receipt.publishedWeek[0].draft.alarm?.snoozeDuration, 540)
            XCTAssertEqual(receipt.publishedWeek[0].draft.alarm?.snoozeTaper, 30)
        }
        let untouched: PersonalRoutineReview = try PersonalRoutineFixtures.decode("untouchedReview")
        try untouched.validate(for: session); XCTAssertFalse(untouched.canPublish)
        XCTAssertThrowsError(try PersonalRoutineRequest(review: untouched, now: PersonalControlFixtures.instant))
        XCTAssertNil(try PersonalControlFixtures.session(for: PersonalControlFixtures.bed()).capabilities.personalRoutinePublication)
    }
    func testFullWeekDeletionAndExactImportPreserveEveryField() throws {
        let review = try PersonalRoutineFixtures.review()
        var draft = try XCTUnwrap(review.liveWeek.first?.draft)
        draft.alarm?.snoozeDuration = 541; draft.alarm?.duration = 27
        draft.temperatures = [.init(time: "23:17", temperature: 68, enabled: true), .init(time: "06:11", temperature: 77, enabled: false)]
        draft.notes = "Keep all fields"
        let week = [BedtimeRoutineSnapshot(dayOfWeek: .sunday, revision: String(repeating: "a", count: 64), draft: draft)]
        let imported = PersonalRoutineWeek.drafts(week)
        XCTAssertEqual(imported.first?.draft, draft)
        XCTAssertEqual(PersonalRoutineWeek.duration(541), "9 min 1 sec")
        XCTAssertEqual(BedtimeRoutineTime.eventDay(.sunday, time: "07:00", start: "22:00"), .monday)
        let changes = PersonalRoutineChange.between(imported, [])
        XCTAssertEqual(changes, [.init(dayOfWeek: .sunday, operation: "remove")])
        let cleared = try PersonalRoutineFixtures.changed(review) {
            $0["draftWeek"] = []; $0["changes"] = [["dayOfWeek": "sunday", "operation": "remove"]]
        }
        try cleared.validate()
        let attempt = try PersonalRoutineFixtures.attempt(review: cleared)
        try PersonalRoutineFixtures.receipt(attempt.request, review: cleared).validate(for: attempt)
    }
    func testIncompleteChangesForeignScopeDuplicateDaysAndInvalidTimeZoneFail() throws {
        let review = try PersonalRoutineFixtures.review(), session = try PersonalRoutineFixtures.session()
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["changes"] = [] }, { $0["timeZone"] = "Not/A_Zone" }, { $0["canPublish"] = false },
            { $0["temperatureZones"] = ["right"] }, { $0["draftRevision"] = 1 },
            { $0["draftWeek"] = ($0["draftWeek"] as? [Any] ?? []) + ($0["draftWeek"] as? [Any] ?? []) }
        ]
        for edit in edits { XCTAssertThrowsError(try PersonalRoutineFixtures.changed(review, edit).validate(for: session)) }
        let foreign = try PersonalRoutineFixtures.changed(review) {
            var scope = $0["scope"] as? [String: Any] ?? [:]; scope["sleeperId"] = UUID().uuidString; $0["scope"] = scope
        }
        XCTAssertThrowsError(try foreign.validate(for: session))
    }
    func testRequestNeedsBothAcknowledgmentsShortExpiryAndNoExtraSide() throws {
        let request: PersonalRoutineRequest = try PersonalRoutineFixtures.decode("publishRequest")
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["confirmReplaceLiveWeek"] = false }, { $0["acknowledgeCurrentTargetEffect"] = false },
            { $0["expiresAt"] = request.issuedAt + 60_001 }, { $0["expiresAt"] = request.issuedAt }
        ]
        for edit in edits { XCTAssertThrowsError(try PersonalRoutineFixtures.changed(request, edit).validate()) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object["side"] = "right"
        XCTAssertThrowsError(try PersonalRoutineRequest.decodeExact(JSONSerialization.data(withJSONObject: object)))
    }
    func testReceiptMustMatchOriginalPlanAndCannotDowngradeRefresh() throws {
        let attempt = try PersonalRoutineFixtures.attempt()
        let receipt = PersonalRoutineFixtures.receipt(attempt.request, review: attempt.review)
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["sourceSide"] = "right" }, { $0["publishedWeek"] = [] }, { $0["draftRevision"] = 7 },
            { $0["requestId"] = UUID().uuidString }, { $0["replayAllowed"] = true },
            { $0["physicalVerification"] = "verified" }, { $0["reviewRevision"] = String(repeating: "e", count: 64) }
        ]
        for edit in edits { XCTAssertThrowsError(try PersonalRoutineFixtures.changed(receipt, edit).validate(for: attempt)) }
        var pending = receipt; pending.scheduler = "pending"
        var unconfirmed = receipt; unconfirmed.scheduler = "unconfirmed"
        XCTAssertFalse(pending.mayReplace(receipt)); XCTAssertFalse(pending.mayReplace(unconfirmed))
        XCTAssertTrue(receipt.mayReplace(pending)); XCTAssertTrue(receipt.mayReplace(unconfirmed))
    }
}
