import XCTest
import CryptoKit
@testable import Sleepypod

enum PersonalLearningFixtures {
    static func data(_ key: String) throws -> Data { try PersonalControlFixtures.data(key, file: "personal-learning-v1") }
    static func session() throws -> HouseholdSession { try JSONDecoder().decode(HouseholdSession.self, from: data("session")) }
    static func archives() throws -> PersonalLearningArchivePage { try .decodeExact(data("archives")) }
    static func records() throws -> PersonalLearningRecordPage { try .decodeExact(data("records")) }
    static func detail() throws -> PersonalLearningDetail { try .decodeExact(data("detail")) }
    static func connection() throws -> PersonalBedConnection { PersonalHistoryFixtures.connection(try session()) }
}

final class PersonalLearningContractTests: XCTestCase {
    func testFrozenCoreFixtureValidatesEveryEnvelopeAndOriginalPayloadHash() throws {
        let session = try PersonalLearningFixtures.session(), archives = try PersonalLearningFixtures.archives()
        let records = try PersonalLearningFixtures.records(), detail = try PersonalLearningFixtures.detail()
        try session.validate(); try archives.validate(for: session, before: nil)
        let archive = try XCTUnwrap(archives.archives.first), record = try XCTUnwrap(records.records.first)
        try records.validate(for: session, archive: archive, after: 0)
        try detail.validate(for: session, archive: archive, record: record)
        XCTAssertEqual(record.recordedDate, "2026-10-30")
        XCTAssertTrue(detail.payload?.contains("Felt comfortable after an earlier bedtime.") == true)
    }
    func testUnknownProjectionAndAbsentRequiredKeysAreRejectedBeforeUse() throws {
        for (name, shape): (String, PersonalLearningDecoding.Shape) in [("archives", .archives), ("records", .records), ("detail", .detail)] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: PersonalLearningFixtures.data(name)) as? [String: Any])
            value["ownerHistory"] = []
            XCTAssertThrowsError(try PersonalLearningDecoding.check(JSONSerialization.data(withJSONObject: value), shape: shape))
            value.removeValue(forKey: "ownerHistory"); value.removeValue(forKey: "scope")
            XCTAssertThrowsError(try PersonalLearningDecoding.check(JSONSerialization.data(withJSONObject: value), shape: shape))
        }
    }
    func testRecordDatesStayOptionalButCannotBecomeInvalidOrApplyToModels() throws {
        let page = try PersonalLearningFixtures.records(), session = try PersonalLearningFixtures.session()
        let archive = try XCTUnwrap(PersonalLearningFixtures.archives().archives.first)
        for value in [NSNull(), "2026-02-30", "2026-10-30"] as [Any] {
            let changed: PersonalLearningRecordPage = try PersonalHistoryFixtures.changed(page) {
                var rows = $0["records"] as! [[String: Any]]; rows[0]["recordedDate"] = value; $0["records"] = rows
            }
            if value as? String == "2026-02-30" { XCTAssertThrowsError(try changed.validate(for: session, archive: archive, after: 0)) }
            else { try changed.validate(for: session, archive: archive, after: 0) }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PersonalLearningFixtures.data("records")) as? [String: Any])
        var rows = object["records"] as! [[String: Any]]; rows[0].removeValue(forKey: "recordedDate"); object["records"] = rows
        try PersonalLearningRecordPage.decodeExact(JSONSerialization.data(withJSONObject: object)).validate(for: session, archive: archive, after: 0)
        rows[0]["recordedDate"] = "2026-10-30"; rows[0]["sourceTable"] = "comfort_models"; object["records"] = rows
        XCTAssertThrowsError(try PersonalLearningRecordPage.decodeExact(JSONSerialization.data(withJSONObject: object)).validate(for: session, archive: archive, after: 0))
    }
    func testScopeSelectorsProvenanceAndPayloadTamperingAreRejected() throws {
        let session = try PersonalLearningFixtures.session(), archives = try PersonalLearningFixtures.archives()
        let page = try PersonalLearningFixtures.records(), detail = try PersonalLearningFixtures.detail()
        let archive = try XCTUnwrap(archives.archives.first), record = try XCTUnwrap(page.records.first)
        XCTAssertThrowsError(try archives.validate(for: session, before: UUID().uuidString))
        XCTAssertThrowsError(try page.validate(for: session, archive: archive, after: 1))
        for field in ["payload", "payloadHash", "activation", "attribution", "encoding", "sourceSide", "recordId"] {
            let changed: PersonalLearningDetail = try PersonalHistoryFixtures.changed(detail) { $0[field] = field == "sourceSide" ? "right" : "invalid" }
            XCTAssertThrowsError(try changed.validate(for: session, archive: archive, record: record), field)
        }
        let other: HouseholdSession = try PersonalHistoryFixtures.changed(session) { $0["accountId"] = UUID().uuidString }
        XCTAssertThrowsError(try archives.validate(for: other, before: nil))
        XCTAssertThrowsError(try page.validate(for: other, archive: archive, after: 0))
        XCTAssertThrowsError(try detail.validate(for: other, archive: archive, record: record))
    }
    func testExactLargeIntegerSourceAndRedactionRemainHistorical() throws {
        let session = try PersonalLearningFixtures.session(), original = try PersonalLearningFixtures.detail()
        let archive = try XCTUnwrap(PersonalLearningFixtures.archives().archives.first)
        let record = try XCTUnwrap(PersonalLearningFixtures.records().records.first)
        let payload = #"{"id":9007199254740993,"side":"left","note":"original"}"#
        let detail: PersonalLearningDetail = try PersonalHistoryFixtures.changed(original) {
            $0["payload"] = payload; $0["payloadHash"] = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let updated: PersonalLearningRecord = try PersonalHistoryFixtures.changed(record) { $0["payloadBytes"] = payload.utf8.count }
        try detail.validate(for: session, archive: archive, record: updated)
        XCTAssertEqual(detail.payload, payload)
        let redacted: PersonalLearningDetail = try PersonalHistoryFixtures.changed(detail) { $0["payload"] = NSNull(); $0["redacted"] = true }
        let removed: PersonalLearningRecord = try PersonalHistoryFixtures.changed(updated) { $0["redacted"] = true }
        try redacted.validate(for: session, archive: archive, record: removed)
        XCTAssertThrowsError(try redacted.validate(for: session, archive: archive, record: updated))
    }

    func testRecordPageCannotExceedPreservedArchiveOrRepeatOrdinals() throws {
        let session = try PersonalLearningFixtures.session(), original = try PersonalLearningFixtures.records()
        let archive = try XCTUnwrap(PersonalLearningFixtures.archives().archives.first)
        for field in ["ordinal", "payloadBytes", "generatedAt", "nextOrdinal"] {
            let altered: PersonalLearningRecordPage = try PersonalHistoryFixtures.changed(original) { value in
                if field == "generatedAt" { value[field] = archive.capturedAt - 1 }
                else if field == "nextOrdinal" { value[field] = 1 }
                else {
                    var records = value["records"] as! [[String: Any]]
                    records[0][field] = field == "ordinal" ? archive.recordCount + 1 : archive.payloadBytes + 1
                    value["records"] = records
                }
            }
            XCTAssertThrowsError(try altered.validate(for: session, archive: archive, after: 0), field)
        }
    }

    func testOriginalExportRetainsUtf8AndLargeIntegerBytes() throws {
        let payload = "{\"id\":9007199254740993,\"note\":\"Café — original\\nnotes\"}"
        XCTAssertEqual(PersonalLearningSourceDocument(source: payload).source, Data(payload.utf8))
    }
}
