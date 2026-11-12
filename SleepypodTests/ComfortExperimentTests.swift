import XCTest
@testable import Sleepypod

enum ComfortExperimentFixtures {
    static func root() throws -> [String: Any] {
        let address = try XCTUnwrap(Bundle.main.url(forResource: "comfort-experiments-v1", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: address)) as? [String: Any])
    }
    static func data(_ name: String, kind: String = "personal") throws -> Data {
        let root = try root(), cases = try XCTUnwrap(root["cases"] as? [String: [String: Any]])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(cases[kind]?[name]))
    }
    static func value<Value: ComfortExperimentEnvelope>(_ name: String, kind: String = "personal", as type: Value.Type = Value.self) throws -> Value {
        try ComfortExperimentDecoding.decode(type, data: data(name, kind: kind))
    }
    static func session() throws -> HouseholdSession {
        try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(root()["session"])))
    }
    static func changed(_ data: Data, _ edit: (inout [String: Any]) throws -> Void) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); try edit(&value)
        return try JSONSerialization.data(withJSONObject: value)
    }
}

final class ComfortExperimentContractTests: XCTestCase {
    func testFrozenOwnerAndPersonalPlanningAndExecutionResponsesMatchController() throws {
        for kind in ["legacy", "personal"] {
            let review: ComfortExperimentReview = try ComfortExperimentFixtures.value("review", kind: kind)
            try review.validate(proposal: .init(firstNightDate: "2026-11-13", variantF: 69))
            try review.validateEnvelope(scope: review.scope, now: review.generatedAt)
            let library: ComfortExperimentLibrary = try ComfortExperimentFixtures.value("savedLibrary", kind: kind)
            try library.validate(); XCTAssertEqual(library.experiments.first?.id, review.plan.id)
            let saved: ComfortExperimentDetail = try ComfortExperimentFixtures.value("saved", kind: kind)
            try saved.validate(id: review.plan.id)
            XCTAssertEqual(saved.record.plan, review.plan)
            XCTAssertEqual(review.nights.count, 16)
            XCTAssertEqual(review.nights.filter { $0.role == "scored" }.count, 8)
            XCTAssertTrue(review.schedule.windows.allSatisfy { $0.wake?.temperatureF == 105 && $0.wake?.vibrationSeconds == 20 })
            for name in ["status", "controlReview", "admitted", "uncertain", "recovered"] {
                let state: ComfortExperimentExecution = try ComfortExperimentFixtures.value(name, kind: kind)
                try state.validate(record: saved.record)
                try state.validateEnvelope(scope: saved.scope, now: state.generatedAt)
            }
            let stopped: ComfortExperimentDetail = try ComfortExperimentFixtures.value("stopped", kind: kind)
            try stopped.validate(id: saved.record.plan.id)
            for name in ["closedControl", "cancelled"] {
                let state: ComfortExperimentExecution = try ComfortExperimentFixtures.value(name, kind: kind)
                try state.validate(record: stopped.record)
            }
        }
    }
    func testRejectsUnexpectedFieldsWrongAccountAndStaleReplies() throws {
        let original = try ComfortExperimentFixtures.data("saved")
        let detail: ComfortExperimentDetail = try ComfortExperimentFixtures.value("saved")
        for edit in [
            { (object: inout [String: Any]) in object["otherSleeper"] = "private" },
            { object in var scope = object["scope"] as! [String: Any]; scope["installationId"] = UUID().uuidString; object["scope"] = scope },
            { object in var record = object["record"] as! [String: Any]; record["rawSensors"] = []; object["record"] = record },
            { object in object.removeValue(forKey: "scope") }
        ] {
            XCTAssertThrowsError(try ComfortExperimentDecoding.decode(ComfortExperimentDetail.self, data: ComfortExperimentFixtures.changed(original, edit)))
        }
        let other = ComfortExperimentScope(kind: "legacy", installationId: UUID().uuidString)
        XCTAssertThrowsError(try detail.validateEnvelope(scope: other, now: detail.generatedAt))
        XCTAssertThrowsError(try detail.validateEnvelope(scope: detail.scope, now: detail.generatedAt + 120_001))
        XCTAssertThrowsError(try detail.validateEnvelope(scope: detail.scope, now: detail.generatedAt - 60_001))
    }
    func testRejectsWrongSchedulesAndMismatchedNightAssignments() throws {
        let data = try ComfortExperimentFixtures.data("saved")
        let edits: [(inout [String: Any]) -> Void] = [
            { value in var record = value["record"] as! [String: Any]; var plan = record["plan"] as! [String: Any]; plan["variantF"] = 80; record["plan"] = plan; value["record"] = record },
            { value in var comparison = value["comparison"] as! [String: Any]; var nights = comparison["nights"] as! [[String: Any]]; nights[0]["targetF"] = 90; comparison["nights"] = nights; value["comparison"] = comparison },
            { value in var record = value["record"] as! [String: Any]; var plan = record["plan"] as! [String: Any]; var schedule = plan["schedule"] as! [String: Any]; var windows = schedule["windows"] as! [[String: Any]]; windows[0]["windowEnd"] = windows[0]["windowStart"]; schedule["windows"] = windows; plan["schedule"] = schedule; record["plan"] = plan; value["record"] = record }
        ]
        for edit in edits {
            let result = try ComfortExperimentDecoding.decode(ComfortExperimentDetail.self, data: ComfortExperimentFixtures.changed(data, edit))
            XCTAssertThrowsError(try result.validate(id: result.record.plan.id))
        }
    }
    func testRejectsAcknowledgmentMasqueradingAsPhysicalProofAndOldRecovery() throws {
        let record = try ComfortExperimentFixtures.value("saved", as: ComfortExperimentDetail.self).record
        let data = try ComfortExperimentFixtures.data("recovered")
        for mutation in ["acknowledgment", "observedAt", "requestedTargetF"] {
            let changed = try ComfortExperimentFixtures.changed(data) { object in
                var applications = object["applications"] as! [[String: Any]]
                if mutation == "observedAt" {
                    var resolution = applications[0]["resolution"] as! [String: Any]
                    resolution["observedAt"] = applications[0]["attemptedAt"]; applications[0]["resolution"] = resolution
                } else if mutation == "acknowledgment" { applications[0][mutation] = "accepted_not_physically_verified" }
                else { applications[0][mutation] = 105 }
                object["applications"] = applications
            }
            let value = try ComfortExperimentDecoding.decode(ComfortExperimentExecution.self, data: changed)
            XCTAssertThrowsError(try value.validate(record: record))
        }
    }
    func testRequestContractCannotCarrySideOrEvidenceAndRejectsPathInjection() throws {
        let id = UUID().uuidString, hash = String(repeating: "a", count: 64)
        let value = try ComfortExperimentRequest.confirmControl(id: id, reviewId: id, hash: hash).payload()
        XCTAssertEqual(value.path, id + "/execution/confirm"); XCTAssertTrue(value.query.isEmpty)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["reviewId", "planHash", "confirmed"])
        for invalid in ["../controls", id + "?side=right", "not-an-id"] {
            XCTAssertThrowsError(try ComfortExperimentRequest.detail(invalid).payload())
            XCTAssertThrowsError(try ComfortExperimentRequest.cancelControl(id: id, admissionId: invalid).payload())
        }
    }
}
