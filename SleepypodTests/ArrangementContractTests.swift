import XCTest
@testable import Sleepypod

final class ArrangementContractTests: XCTestCase {
    func testFrozenPrivateProjectionsPreserveOwnerOperatingWeekAndMemberEmptyDraft() throws {
        for member in [false, true] {
            let session = try ArrangementFixtures.session(member: member), review = try ArrangementFixtures.review(member: member)
            try session.validate(); try review.validate(for: session)
            XCTAssertFalse(review.canActivate); XCTAssertNotEqual(review.person.proposedSide, review.partner.proposedSide)
            let object = try ArrangementJSON.object(JSONEncoder().encode(review))
            try ArrangementJSON.keys(object["partner"], ["displayName", "proposedSide", "approved"])
            XCTAssertEqual(review.person.week.count, member ? 0 : 1)
        }
        let owner = try ArrangementFixtures.review()
        XCTAssertEqual(owner.person.week.first?.draft.alarm?.snoozeDuration, 540)
        XCTAssertEqual(owner.person.week.first?.draft.alarm?.snoozeTaper, 30)
        XCTAssertEqual(owner.person.week.first?.draft.notes, "Synthetic example only")
    }
    func testPrivatePartnerFieldsActivationForeignPersonAndMalformedValuesAreRejected() throws {
        let session = try ArrangementFixtures.session(), original = try ArrangementFixtures.review()
        for field in ["week", "preferences", "health", "sleepHistory", "accountId"] {
            var object = try ArrangementJSON.object(ArrangementFixtures.data("ownerReview"))
            var partner = try XCTUnwrap(object["partner"] as? [String: Any]); partner[field] = []; object["partner"] = partner
            XCTAssertThrowsError(try ArrangementReview.decodeExact(JSONSerialization.data(withJSONObject: object)))
        }
        let invalid: [[String: Any]] = [["canActivate": true], ["sleeperId": UUID().uuidString], ["assignmentRevision": 2],
                                      ["expiresAt": original.createdAt], ["timeZone": "Mars/Nope"], ["effect": "activated"], ["state": "approved_for_separate_activation"]]
        for changes in invalid {
            let value = try PersonalRoutineFixtures.changed(original) { $0.merge(changes) { _, new in new } }
            XCTAssertThrowsError(try value.validate(for: session))
        }
    }
    func testExactRequestsRequireAllIndependentAcknowledgmentsAndBoundedFreshness() throws {
        let session = try ArrangementFixtures.session()
        for (key, action) in [("propose", ArrangementRequest.Action.propose), ("approve", .approve), ("cancel", .cancel)] {
            _ = try ArrangementRequest.decodeExact(ArrangementFixtures.data(key), action: action, session: session)
            var invalid = try ArrangementJSON.object(ArrangementFixtures.data(key)); invalid["activate"] = true
            XCTAssertThrowsError(try ArrangementRequest.decodeExact(JSONSerialization.data(withJSONObject: invalid), action: action, session: session))
        }
        for field in ["confirmMySide", "confirmMyRoutine", "acknowledgeSeparateActivation"] {
            var invalid = try ArrangementJSON.object(ArrangementFixtures.data("approve")); invalid[field] = false
            XCTAssertThrowsError(try ArrangementRequest.decodeExact(JSONSerialization.data(withJSONObject: invalid), action: .approve, session: session))
        }
        var invalid = try ArrangementJSON.object(ArrangementFixtures.data("approve")); invalid["expiresAt"] = 1_793_311_262_000 as Int64
        XCTAssertThrowsError(try ArrangementRequest.decodeExact(JSONSerialization.data(withJSONObject: invalid), action: .approve, session: session))
        XCTAssertThrowsError(try ArrangementRequest.decodeExact(ArrangementFixtures.data("propose"), action: .propose, session: ArrangementFixtures.session(member: true)))
    }
    func testCapabilityIsBackwardCompatibleAndExpiryIncludesClockRollback() throws {
        let old = try JSONDecoder().decode(HouseholdSession.self, from: PersonalControlFixtures.data("ownerSession", file: "household-preparation-v1"))
        XCTAssertNil(old.capabilities.arrangementReview)
        let review = try ArrangementFixtures.review()
        XCTAssertEqual(review.state(at: review.createdAt - 1), .expired)
        XCTAssertEqual(review.state(at: review.createdAt), .awaitingApproval)
        XCTAssertEqual(review.state(at: review.expiresAt), .expired)
        var cancelled = review; cancelled.state = .cancelled
        XCTAssertEqual(cancelled.state(at: review.expiresAt), .cancelled)
    }
}
