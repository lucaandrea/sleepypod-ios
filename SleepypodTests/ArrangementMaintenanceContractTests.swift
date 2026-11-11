import XCTest
@testable import Sleepypod

enum MaintenanceFixtures {
    static let now: Int64 = 1_794_337_200_000
    static let operationId = "10000000-0000-4000-8000-000000000088"
    static func data(_ key: String) throws -> Data { try PersonalControlFixtures.data(key, file: "household-maintenance-v1") }
    static func session(member: Bool = false) throws -> HouseholdSession {
        try PersonalRoutineFixtures.changed(ArrangementFixtures.session(member: member)) {
            var capabilities = $0["capabilities"] as? [String: Any] ?? [:]
            capabilities["arrangementMaintenance"] = !member
            capabilities["activateArrangement"] = !member
            $0["capabilities"] = capabilities
        }
    }
    static func changed(_ key: String, mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try ArrangementJSON.object(data(key)); mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func changedOperation(_ key: String, mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try ArrangementJSON.object(data(key))
        var operation = try XCTUnwrap(object["operation"] as? [String: Any]); mutate(&operation); object["operation"] = operation
        return try JSONSerialization.data(withJSONObject: object)
    }
}

final class ArrangementMaintenanceContractTests: XCTestCase {
    func testCoreGeneratedStatusesValidateWithoutClaimingPhysicalMovement() throws {
        let session = try MaintenanceFixtures.session()
        for key in ["empty", "held", "committed", "restartSubmitted", "readyToRecover", "completed", "cancelled"] {
            let value = try ArrangementMaintenanceStatus.decodeExact(MaintenanceFixtures.data(key))
            try value.validate(for: session, now: MaintenanceFixtures.now)
            XCTAssertEqual(value.operation?.recovery?.physicalMovement ?? "not_requested", "not_requested")
        }
    }
    func testMalformedPrivateProjectionCannotSlipThroughOptionalFields() throws {
        let data = try MaintenanceFixtures.changed("held") { $0["privateArchive"] = ["partnerHistory": []] }
        XCTAssertThrowsError(try ArrangementMaintenanceStatus.decodeExact(data))
        for field in ["operationId", "committedAt", "controllerRestarted", "recovery", "cancellation", "restart"] {
            let missing = try MaintenanceFixtures.changedOperation("held") { $0.removeValue(forKey: field) }
            XCTAssertThrowsError(try ArrangementMaintenanceStatus.decodeExact(missing), field)
        }
        let extra = try MaintenanceFixtures.changedOperation("completed") {
            var receipt = $0["recovery"] as? [String: Any] ?? [:]; receipt["processing"] = ["private": true]; $0["recovery"] = receipt
        }
        XCTAssertThrowsError(try ArrangementMaintenanceStatus.decodeExact(extra))
    }
    func testFreshnessAssignmentAndOperationBindingAreRequired() throws {
        let session = try MaintenanceFixtures.session()
        let value = try ArrangementMaintenanceStatus.decodeExact(MaintenanceFixtures.data("held"))
        for now in [MaintenanceFixtures.now - 1, MaintenanceFixtures.now + 15_001] {
            XCTAssertThrowsError(try value.validate(for: session, now: now))
        }
        XCTAssertThrowsError(try value.validate(for: session, now: MaintenanceFixtures.now, operationId: UUID().uuidString))
        let changed = try PersonalRoutineFixtures.changed(session) { $0["assignmentRevision"] = 2 }
        XCTAssertThrowsError(try value.validate(for: changed, now: MaintenanceFixtures.now))
        XCTAssertThrowsError(try value.validate(for: MaintenanceFixtures.session(member: true), now: MaintenanceFixtures.now))
    }
    func testMaintenanceCanFollowOnlyItsSameOwnerAcrossAnAssignmentChange() throws {
        let original = try MaintenanceFixtures.session()
        let changed = try PersonalRoutineFixtures.changed(original) {
            $0["sessionRevision"] = 2; $0["assignmentRevision"] = 2
            $0["arrangement"] = ["mode": "assigned", "effectiveAt": "2026-11-11T15:00:00Z"]
            $0["self"] = ["displayName": "Owner", "assignment": "right", "zones": ["right"]]
        }
        try ArrangementMaintenanceValidation.owner(changed, anchoredTo: original)
        for field in ["podId", "householdId", "accountId", "selfSleeperId"] {
            let other = try PersonalRoutineFixtures.changed(changed) { $0[field] = UUID().uuidString }
            XCTAssertThrowsError(try ArrangementMaintenanceValidation.owner(other, anchoredTo: original), field)
        }
        XCTAssertThrowsError(try ArrangementMaintenanceValidation.owner(MaintenanceFixtures.session(member: true), anchoredTo: original))
    }
    func testInconsistentStatusAndReceiptTimesAreRejected() throws {
        let session = try MaintenanceFixtures.session()
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("held", { $0["committedAt"] = MaintenanceFixtures.now - 100 }),
            ("committed", { $0["committedAt"] = NSNull() }),
            ("committed", { $0["committedAt"] = MaintenanceFixtures.now + 1 }),
            ("completed", { $0["recovery"] = NSNull() }),
            ("cancelled", { $0["cancellation"] = NSNull() }),
            ("restartSubmitted", { var receipt = $0["restart"] as? [String: Any] ?? [:]; receipt["replayAllowed"] = true; $0["restart"] = receipt }),
            ("restartSubmitted", { var receipt = $0["restart"] as? [String: Any] ?? [:]; receipt["resultAt"] = NSNull(); $0["restart"] = receipt }),
            ("restartSubmitted", { var receipt = $0["restart"] as? [String: Any] ?? [:]; receipt["operationId"] = UUID().uuidString; $0["restart"] = receipt }),
            ("completed", { var receipt = $0["recovery"] as? [String: Any] ?? [:]; receipt["recordingStartsAt"] = MaintenanceFixtures.now + 1; $0["recovery"] = receipt }),
            ("cancelled", { var receipt = $0["cancellation"] as? [String: Any] ?? [:]; receipt["controlDigest"] = "invalid"; $0["cancellation"] = receipt })
        ]
        for (key, mutate) in cases {
            XCTAssertThrowsError(try ArrangementMaintenanceStatus.decodeExact(MaintenanceFixtures.changedOperation(key, mutate: mutate)).validate(for: session, now: MaintenanceFixtures.now), key)
        }
    }
    func testCancellationPreviewBindsFreshDigestToCurrentAccount() throws {
        let session = try MaintenanceFixtures.session()
        let preview = try ArrangementCancellationPreview.decodeExact(MaintenanceFixtures.data("cancellationPreview"))
        try preview.validate(for: session, operationId: MaintenanceFixtures.operationId, now: MaintenanceFixtures.now)
        XCTAssertThrowsError(try preview.validate(for: session, operationId: MaintenanceFixtures.operationId, now: MaintenanceFixtures.now + 60_001, maximumAge: 60_000))
        XCTAssertThrowsError(try preview.validate(for: session, operationId: UUID().uuidString, now: MaintenanceFixtures.now))
        let extra = try MaintenanceFixtures.changed("cancellationPreview") { $0["side"] = "left" }
        XCTAssertThrowsError(try ArrangementCancellationPreview.decodeExact(extra))
    }
    func testEveryActionUsesItsOwnExactConfirmationSetAndCoreContract() throws {
        let session = try MaintenanceFixtures.session()
        for action in [ArrangementMaintenanceRequest.Action.activate, .restart, .recover, .cancel] {
            let request = try ArrangementMaintenanceRequest.decodeExact(MaintenanceFixtures.data("\(action.rawValue)Request"), action: action, session: session, now: MaintenanceFixtures.now)
            let fresh = try ArrangementMaintenanceRequest(action: action, session: session, referenceId: request.referenceId,
                confirmations: action.confirmations, now: MaintenanceFixtures.now,
                controlDigest: action == .cancel ? String(repeating: "a", count: 64) : nil)
            XCTAssertNotEqual(fresh.requestId, request.requestId)
            XCTAssertEqual(fresh.action.path, "household/transition" + (action == .activate ? "" : "/\(action.rawValue)"))
            XCTAssertThrowsError(try ArrangementMaintenanceRequest(action: action, session: session, referenceId: request.referenceId,
                confirmations: [], now: MaintenanceFixtures.now))
            for field in action.confirmations {
                for replacement in [false, 1, "true"] as [Any] {
                    let changed = try MaintenanceFixtures.changed("\(action.rawValue)Request") { $0[field] = replacement }
                    XCTAssertThrowsError(try ArrangementMaintenanceRequest.decodeExact(changed, action: action, session: session, now: MaintenanceFixtures.now), field)
                }
            }
        }
    }
    func testExpiredCrossIdentityAndExtraSelectorRequestsNeverValidate() throws {
        let session = try MaintenanceFixtures.session()
        let original = try MaintenanceFixtures.data("restartRequest")
        XCTAssertThrowsError(try ArrangementMaintenanceRequest.decodeExact(original, action: .restart, session: session, now: MaintenanceFixtures.now - 1))
        XCTAssertThrowsError(try ArrangementMaintenanceRequest.decodeExact(original, action: .restart, session: session, now: MaintenanceFixtures.now + 60_000))
        let changed = try PersonalRoutineFixtures.changed(session) { $0["sessionRevision"] = 2 }
        XCTAssertThrowsError(try ArrangementMaintenanceRequest.decodeExact(original, action: .restart, session: changed, now: MaintenanceFixtures.now))
        let extra = try MaintenanceFixtures.changed("restartRequest") { $0["side"] = "right" }
        XCTAssertThrowsError(try ArrangementMaintenanceRequest.decodeExact(extra, action: .restart, session: session, now: MaintenanceFixtures.now))
        XCTAssertThrowsError(try ArrangementMaintenanceRequest.decodeExact(original, action: .restart, session: MaintenanceFixtures.session(member: true), now: MaintenanceFixtures.now))
    }
}
