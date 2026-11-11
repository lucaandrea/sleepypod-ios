import XCTest
@testable import Sleepypod

@MainActor final class TonightTests: XCTestCase {
    private final class ReadSwitch { var fails = false }
    private let now = Date(timeIntervalSince1970: 1_794_326_400)
    private func comfort(mode: String = "preview", active: Bool = true, paused: Bool = false) throws -> PersonalComfortStatus {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PersonalComfortExample.load().status)) as? [String: Any])
        fields["generatedAt"] = now.timeIntervalSince1970 * 1000; fields["runtime"] = "running"
        var state = try XCTUnwrap(fields["state"] as? [String: Any]), config = try XCTUnwrap(state["config"] as? [String: Any])
        config["mode"] = mode; state["config"] = config; state["pausedUntil"] = paused ? now.addingTimeInterval(300).timeIntervalSince1970 * 1000 : 0
        fields["state"] = state
        var activation = try XCTUnwrap(fields["activation"] as? [String: Any]); activation["current"] = active; fields["activation"] = activation
        return try JSONDecoder().decode(PersonalComfortStatus.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func testModeRequiresCurrentSourceAndActualActivation() throws {
        XCTAssertEqual(TonightSummary.mode(try comfort(), now: now), "Preview · no adjustments")
        XCTAssertEqual(TonightSummary.mode(try comfort(mode: "off"), now: now), "Off")
        XCTAssertEqual(TonightSummary.mode(try comfort(mode: "active"), now: now), "Active · bounded adjustments")
        XCTAssertEqual(TonightSummary.mode(try comfort(mode: "active", active: false), now: now), "Activation not confirmed")
        XCTAssertEqual(TonightSummary.mode(try comfort(mode: "active", paused: true), now: now), "Paused after manual control")
        XCTAssertEqual(TonightSummary.mode(try comfort(), now: now.addingTimeInterval(91)), "Not checked")
        XCTAssertEqual(TonightSummary.mode(try comfort(), now: now.addingTimeInterval(-61)), "Not checked")
    }
    func testPlanFollowsScheduleOwnershipWithoutConfusingIndependentZonesWithSleepProfile() async throws {
        var settings = try await MockClient().getSettings()
        settings.bedMode = "solo-left"; settings.left.awayMode = false
        settings.unusedZoneMode = "follow"
        XCTAssertEqual(TonightSummary.planSide(selected: .right, settings: settings), .left)
        settings.unusedZoneMode = "independent"
        XCTAssertEqual(TonightSummary.planSide(selected: .right, settings: settings), .right)
        XCTAssertEqual(settings.contextSide(selected: .right), .left)
        XCTAssertEqual(TonightSummary.planSide(selected: .right, settings: nil), .right)
    }
    func testMorningUsesPodTimezoneAndDaylightSavingBoundary() throws {
        let morning = try XCTUnwrap(NextAlarmState.instant("2026-11-10T16:00:00Z"))
        XCTAssertTrue(TonightSummary.isMorning(now: morning, timeZone: "America/Los_Angeles"))
        XCTAssertFalse(TonightSummary.isMorning(now: morning, timeZone: "Asia/Tokyo"))
        XCTAssertFalse(TonightSummary.isMorning(now: morning, timeZone: "bad"))
        XCTAssertFalse(TonightSummary.isMorning(now: try XCTUnwrap(NextAlarmState.instant("2026-11-01T11:30:00Z")), timeZone: "America/Los_Angeles"))
        XCTAssertTrue(TonightSummary.isMorning(now: try XCTUnwrap(NextAlarmState.instant("2026-11-01T12:30:00Z")), timeZone: "America/Los_Angeles"))
    }
    func testWakeSummaryRequiresMatchingOccurrenceAndNeverInventsWarmup() throws {
        let page = try XCTUnwrap(NextAlarmExample.load().cases["scheduled"])
        let alarm = try XCTUnwrap(page.alarm), at = try XCTUnwrap(NextAlarmState.instant(alarm.at))
        let before = at.addingTimeInterval(-3600)
        let limit = ComfortLimitPage(apiVersion: 1, side: page.side, sourceSide: page.side, revision: 1,
            config: .init(enabled: true, minF: 68, maxF: 72),
            wake: .init(startsAt: at.addingTimeInterval(-1800).timeIntervalSince1970 * 1000,
                        alarmAt: at.timeIntervalSince1970 * 1000, targetF: alarm.alarmTemperatureF, timeZone: page.timeZone), wakeAvailable: true)
        XCTAssertTrue(TonightSummary.nextWake(page, now: before).contains("vibration"))
        XCTAssertTrue(TonightSummary.warming(alarm: page, limit: limit, now: before).contains("Warming from"))
        XCTAssertTrue(TonightSummary.warming(alarm: page, limit: nil, now: before).contains("Warming not confirmed"))
        XCTAssertTrue(TonightSummary.nextWake(page, now: at.addingTimeInterval(1)).contains("passed"))
        XCTAssertFalse(TonightSummary.warming(alarm: page, limit: limit, now: at.addingTimeInterval(1)).contains("Warming from"))
    }
    func testReceiptsExpireAndDisappearAcrossOwnerChanges() async throws {
        var owner = ["first"]
        let model = TonightWorkspace(currentOwner: { owner })
        let value = try comfort()
        model.configure(side: value.side, comfort: { _ in value }, alarm: nil, limit: nil)
        await model.refresh()
        XCTAssertNotNil(model.comfort(at: .now))
        XCTAssertNil(model.comfort(at: .now.addingTimeInterval(91)))
        owner = ["second"]
        XCTAssertNil(model.comfort(at: .now))
    }
    func testFailedReadWithdrawsItsResultButKeepsIndependentReads() async throws {
        let model = TonightWorkspace(currentOwner: { ["owner"] })
        let value = try comfort()
        let limit = ComfortLimitPage(apiVersion: 1, side: value.side, sourceSide: value.side, revision: 0,
                                     config: .init(enabled: true, minF: 68, maxF: 72), wake: nil, wakeAvailable: true)
        let control = ReadSwitch()
        model.configure(side: value.side, comfort: { _ in
            if control.fails { throw URLError(.networkConnectionLost) }; return value
        }, alarm: nil, limit: { _ in limit })
        await model.refresh()
        XCTAssertNotNil(model.comfort(at: .now))
        control.fails = true
        await model.refresh()
        XCTAssertNil(model.comfort(at: .now))
        XCTAssertNotNil(model.limit(at: .now))
    }
    func testLateOwnerResponseAndWrongSideAreRejected() async throws {
        var owner = ["first"]
        let model = TonightWorkspace(currentOwner: { owner })
        let value = try comfort()
        model.configure(side: value.side, comfort: { _ in owner = ["second"]; return value }, alarm: nil, limit: nil)
        await model.refresh()
        XCTAssertNil(model.comfort(at: .now))
        model.configure(side: value.side == .left ? .right : .left, comfort: { _ in value }, alarm: nil, limit: nil)
        await model.refresh()
        XCTAssertNil(model.comfort(at: .now))
        model.invalidate()
        XCTAssertNil(model.limit(at: .now))
    }
}
