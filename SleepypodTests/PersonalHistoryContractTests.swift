import XCTest
@testable import Sleepypod

final class PersonalHistoryContractTests: XCTestCase {
    func testFrozenFixtureRetainsCompleteOverlapAndSourceMeanings() throws {
        let session = try PersonalHistoryFixtures.session(); try session.validate()
        for key in ["page", "vitalsPage", "movementPage", "emptyPage"] {
            let page = try PersonalHistoryFixtures.page(key)
            try page.validate(for: session, requested: page.query)
            XCTAssertEqual(try PersonalHistoryPage.decodeExact(JSONEncoder().encode(page)), page)
        }
        let page = try PersonalHistoryFixtures.page(), detail = try PersonalHistoryFixtures.detail()
        try detail.validate(for: session)
        XCTAssertEqual(page.records.first, detail.record)
        XCTAssertLessThan(detail.record.startsAt, page.query.startsAt); XCTAssertGreaterThan(detail.record.endsAt, page.query.endsAt)
        XCTAssertEqual(detail.record.payload, .presence(seconds: 25_200, exits: 2))
        let vitals = try XCTUnwrap(PersonalHistoryFixtures.page("vitalsPage").records.first)
        XCTAssertEqual(vitals.payload, .vitals(heartRate: 61, breathingRate: nil, hrv: 28, metric: .windowVariability))
    }
    func testAllIdentityAndRevisionFieldsArePinned() throws {
        let page = try PersonalHistoryFixtures.page(), session = try PersonalHistoryFixtures.session()
        for field in ["podId", "householdId", "accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"] {
            let changed = try PersonalHistoryFixtures.changed(page) { value in
                var scope = try XCTUnwrap(value["scope"] as? [String: Any]); scope[field] = field.hasSuffix("Revision") ? 2 : UUID().uuidString; value["scope"] = scope
            }
            XCTAssertThrowsError(try changed.validate(for: session, requested: page.query))
        }
        let foreign = try PersonalHistoryFixtures.changed(page) { value in
            var records = try XCTUnwrap(value["records"] as? [[String: Any]]); records[0]["sleeperId"] = UUID().uuidString; value["records"] = records
        }
        XCTAssertThrowsError(try foreign.validate(for: session, requested: page.query))
    }
    func testUnexpectedPrivateFieldsAndMissingNullableKeysAreRejected() throws {
        for field in ["partner", "side", "sleepScore", "health", "accountHistory"] {
            var value = try PersonalHistoryFixtures.object("page"); value[field] = []
            XCTAssertThrowsError(try PersonalHistoryPage.decodeExact(JSONSerialization.data(withJSONObject: value)))
        }
        for location in ["scope", "query", "record", "attribution", "payload"] {
            var value = try PersonalHistoryFixtures.object("page")
            if location == "scope" || location == "query" {
                var nested = try XCTUnwrap(value[location] as? [String: Any]); nested["extra"] = true; value[location] = nested
            } else {
                var records = try XCTUnwrap(value["records"] as? [[String: Any]])
                if location == "record" { records[0]["extra"] = true }
                else { var nested = try XCTUnwrap(records[0][location] as? [String: Any]); nested["extra"] = true; records[0][location] = nested }
                value["records"] = records
            }
            XCTAssertThrowsError(try PersonalHistoryPage.decodeExact(JSONSerialization.data(withJSONObject: value)))
        }
        var value = try PersonalHistoryFixtures.object("vitalsPage")
        var records = try XCTUnwrap(value["records"] as? [[String: Any]])
        var payload = try XCTUnwrap(records[0]["payload"] as? [String: Any]); payload.removeValue(forKey: "breathingRatePerMinute")
        records[0]["payload"] = payload; value["records"] = records
        XCTAssertThrowsError(try PersonalHistoryPage.decodeExact(JSONSerialization.data(withJSONObject: value)))
    }
    func testInvalidEnvelopesQueriesOrderingAndCursorShapesAreRejected() throws {
        let page = try PersonalHistoryFixtures.page(), session = try PersonalHistoryFixtures.session()
        for change: [String: Any] in [["version": 2], ["source": "watch"], ["interpretation": "confirmed_sleep"], ["attributionRevision": 0],
                                     ["generatedAt": -1], ["intervalSelection": "clipped"], ["nextCursor": ""], ["nextCursor": "opaque"], ["records": [] , "nextCursor": "opaque"]] {
            let changed = try PersonalHistoryFixtures.changed(page) { $0.merge(change) { _, new in new } }
            XCTAssertThrowsError(try changed.validate(for: session, requested: page.query))
        }
        let duplicate = try PersonalHistoryFixtures.changed(page) { $0["records"] = try HouseholdRequestBody.object(page.records + page.records) }
        XCTAssertThrowsError(try duplicate.validate(for: session, requested: page.query))
        for query in [PersonalHistoryQuery(startsAt: 0, endsAt: 90 * 86_400_000 + 1, kind: .presence, limit: 30),
                      .init(startsAt: 2, endsAt: 1, kind: .presence, limit: 1), .init(startsAt: -1, endsAt: 1, kind: .presence, limit: 1),
                      .init(startsAt: 0, endsAt: 1, kind: .presence, limit: 0), .init(startsAt: 0, endsAt: 1, kind: .presence, limit: 101)] {
            XCTAssertThrowsError(try query.validate())
        }
        let outside = try PersonalHistoryFixtures.changed(page) { value in
            var records = try XCTUnwrap(value["records"] as? [[String: Any]]); records[0]["startsAt"] = page.query.endsAt; records[0]["endsAt"] = page.query.endsAt + 28_800_000; value["records"] = records
        }
        XCTAssertThrowsError(try outside.validate(for: session, requested: page.query))
    }
    func testPayloadAndIntervalBoundsDoNotInventMeasurements() throws {
        for payload: PersonalHistoryPayload in [.presence(seconds: 61, exits: 0), .presence(seconds: -1, exits: 0), .presence(seconds: 0, exits: 10_001),
                                               .vitals(heartRate: 0, breathingRate: nil, hrv: nil, metric: .unknown),
                                               .vitals(heartRate: nil, breathingRate: 101, hrv: nil, metric: .unknown),
                                               .vitals(heartRate: nil, breathingRate: nil, hrv: 2_001, metric: .unknown), .movement(total: -.infinity)] {
            XCTAssertThrowsError(try payload.validate(intervalMilliseconds: 60_000))
        }
        try PersonalHistoryPayload.vitals(heartRate: nil, breathingRate: nil, hrv: nil, metric: .unknown).validate(intervalMilliseconds: 1)
        XCTAssertEqual(PersonalHistoryPresentation.number(nil), "Unavailable")
        let record = try PersonalHistoryFixtures.detail().record
        for endsAt in [record.startsAt, record.startsAt + 86_400_001] {
            let changed = try PersonalHistoryFixtures.changed(record) { $0["endsAt"] = endsAt }
            XCTAssertThrowsError(try changed.validate(sleeperId: record.sleeperId))
        }
    }
}
