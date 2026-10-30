import XCTest
@testable import Sleepypod

final class PersonalControlContractTests: XCTestCase {
    func testFrozenBedFixturesAndHistoricalReceipts() throws {
        for name in ["soloBed", "assignedBed", "unassignedBed", "disabledBed"] {
            let bed = try PersonalControlFixtures.bed(name)
            try bed.validate(for: PersonalControlFixtures.session(for: bed))
        }
        let body = try PersonalControlFixtures.data("temperatureRequest")
        let request = try JSONDecoder().decode(PersonalControlRequest.self, from: body)
        let attempt = PersonalControlAttempt(request: request, body: body, authorizedZones: [.left, .right])
        for name in ["acknowledged", "partialUnknown"] {
            let receipt = try JSONDecoder().decode(PersonalControlReceipt.self, from: PersonalControlFixtures.data(name))
            try receipt.validate(for: attempt)
            XCTAssertFalse(receipt.replayAllowed); XCTAssertEqual(receipt.physicalVerification, "unverified")
        }
    }
    func testExtraSideAndLegacyOrInvalidActionsAreRejected() throws {
        for json in [
            #"{"kind":"temperature","temperatureF":70,"holdMinutes":30,"side":"right"}"#,
            #"{"kind":"temperature","temperatureF":111,"holdMinutes":30}"#,
            #"{"kind":"temperature","temperatureF":70,"holdMinutes":0}"#,
            #"{"kind":"power","powered":true,"holdMinutes":30}"#,
            #"{"kind":"power","powered":true,"temperatureF":null}"#,
            #"{"kind":"vibration","intensity":50}"#,
            #"{"kind":"base.position","head":30,"feet":15}"#
        ] { XCTAssertThrowsError(try JSONDecoder().decode(PersonalControlAction.self, from: Data(json.utf8))) }
    }
    func testReceiptsMustMatchSavedIdentityActionTimeAndHistoricalTargets() throws {
        let body = try PersonalControlFixtures.data("temperatureRequest"), request = try JSONDecoder().decode(PersonalControlRequest.self, from: body)
        let attempt = PersonalControlAttempt(request: request, body: body, authorizedZones: [.left, .right])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: PersonalControlFixtures.data("acknowledged")) as? [String: Any])
        let changes: [(String, Any)] = [
            ("requestId", UUID().uuidString), ("resolvedZones", ["left"]), ("resolvedZones", ["left", "left"]),
            ("replayAllowed", true), ("physicalVerification", "verified"), ("issuedAt", request.issuedAt + 1),
            ("action", ["kind": "power", "powered": false]), ("dispatchCount", 0)
        ]
        for (key, value) in changes {
            var changed = original; changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(PersonalControlReceipt.self, from: JSONSerialization.data(withJSONObject: changed)).validate(for: attempt), key)
        }
    }
    func testBedRejectsForeignZonesAndUnavailableDataPresentedAsLive() throws {
        let bed = try PersonalControlFixtures.bed("assignedBed"), session = try PersonalControlFixtures.session(for: bed)
        let foreign = try PersonalControlFixtures.changed(bed, side: "right")
        XCTAssertThrowsError(try foreign.validate(for: session))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PersonalControlFixtures.data("unassignedBed")) as? [String: Any])
        object["zones"] = [["side": "left", "measuredTemperatureF": 75, "reportedTargetF": 70, "reportedPowered": true, "requestedTargetF": 70]]
        let changed = try JSONDecoder().decode(PersonalBed.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try changed.validate(for: PersonalControlFixtures.session(for: PersonalControlFixtures.bed("unassignedBed"))))
    }
    func testRequestExpiryAndPersistedBytesAreValidated() throws {
        let body = try PersonalControlFixtures.data("temperatureRequest")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        object["expiresAt"] = 1_793_314_861_000 as Int64
        XCTAssertThrowsError(try JSONDecoder().decode(PersonalControlRequest.self, from: JSONSerialization.data(withJSONObject: object)).validate())
        let request = try JSONDecoder().decode(PersonalControlRequest.self, from: body)
        let another = try PersonalControlRequest(scope: request.scope, action: .init(kind: "power", powered: true), now: PersonalControlFixtures.instant)
        let attempt = PersonalControlAttempt(request: request, body: try JSONEncoder().encode(another), authorizedZones: [.left, .right])
        XCTAssertThrowsError(try attempt.validate())
    }
}
