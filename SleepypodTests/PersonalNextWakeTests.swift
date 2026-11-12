import XCTest
@testable import Sleepypod

@MainActor final class PersonalNextWakeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_278_800)
    private func fixture() throws -> (PersonalBed, PersonalNextWake) {
        let bed = try JSONDecoder().decode(PersonalBed.self, from: PersonalControlFixtures.data("bed", file: "personal-next-wake-v1"))
        let wake = try JSONDecoder().decode(PersonalNextWake.self, from: PersonalControlFixtures.data("wake", file: "personal-next-wake-v1"))
        return (bed, wake)
    }
    func testAcceptsOnlyFreshWakeBoundToTheSamePersonAndRouting() throws {
        let (bed, wake) = try fixture()
        XCTAssertNoThrow(try wake.validate(for: bed, now: now))
        XCTAssertThrowsError(try wake.validate(for: bed, now: now.addingTimeInterval(15)))
        XCTAssertThrowsError(try wake.validate(for: bed, now: now.addingTimeInterval(-1)))
        for changed in [try PersonalControlFixtures.changed(bed, assignment: 2),
                        try PersonalControlFixtures.changed(bed, configuration: String(repeating: "b", count: 64)),
                        try PersonalControlFixtures.changed(bed, side: "right")] {
            XCTAssertThrowsError(try wake.validate(for: changed, now: now))
        }
    }
    func testRejectsMutationAuthorityAndUnsupportedEnvelope() throws {
        let (bed, wake) = try fixture()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wake)) as? [String: Any])
        for key in ["version", "effect", "canChange", "sourceSide", "sleeperId"] {
            var changed = object
            if key == "version" { changed[key] = 2 }
            if key == "effect" { changed[key] = "write" }
            if key == "sourceSide" { changed[key] = "right" }
            if key == "canChange" {
                var plan = try XCTUnwrap(changed["plan"] as? [String: Any]); plan[key] = true; changed["plan"] = plan
            }
            if key == "sleeperId" {
                var scope = try XCTUnwrap(changed["scope"] as? [String: Any]); scope[key] = UUID().uuidString; changed["scope"] = scope
            }
            let value = try JSONDecoder().decode(PersonalNextWake.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try value.validate(for: bed, now: now), key)
        }
    }
    func testWakeSummaryIncludesScheduledWarmingAndDurationButDoesNotReinstateSkippedAlarms() throws {
        let (_, wake) = try fixture()
        let text = BedRemoteWakeSummary.text(wake.plan)
        XCTAssertTrue(text.contains("Warming starts")); XCTAssertTrue(text.contains("Vibration:"))
        let skipped = try XCTUnwrap(NextAlarmExample.load().cases["skipped"])
        let skippedText = BedRemoteWakeSummary.text(skipped)
        XCTAssertTrue(skippedText.contains("Skipped once")); XCTAssertFalse(skippedText.contains("Warming starts"))
        let unknown = try XCTUnwrap(NextAlarmExample.load().cases["unknown"])
        XCTAssertTrue(BedRemoteWakeSummary.text(unknown).contains("physical vibration is unverified"))
    }
    func testPersonalTransportAllowlistProvidesNoAlarmMutation() {
        XCTAssertEqual(HouseholdHTTPClient.methods["me/alarm/next"], ["GET"])
        XCTAssertNil(HouseholdHTTPClient.methods["alarm/next"])
        XCTAssertNil(HouseholdHTTPClient.methods["me/alarm/override"])
    }
}
