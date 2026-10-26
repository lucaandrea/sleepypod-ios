import XCTest
@testable import Sleepypod

@MainActor final class SystemDashboardTests: XCTestCase {
    func testMaintenanceRespectsCapabilitiesScheduleAndSevenDayBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func facts(speed: Bool?, daily: Bool = false, age: Double? = nil) -> SystemMaintenanceFacts {
            .init(pumpStallProtectionEnabled: false, reportsPumpSpeed: speed, primePodDaily: daily, primePodTime: nil,
                  lastPrimeAt: age.map { now.addingTimeInterval(-$0).timeIntervalSince1970 * 1000 }, firstPrimeRecordedAt: nil)
        }
        XCTAssertFalse(facts(speed: false).needsPumpProtection)
        XCTAssertTrue(facts(speed: nil).needsPumpProtection)
        XCTAssertTrue(facts(speed: true).needsPrime(at: now))
        XCTAssertFalse(facts(speed: true, daily: true).needsPrime(at: now))
        XCTAssertFalse(facts(speed: true, age: 7 * 86400).needsPrime(at: now))
        XCTAssertTrue(facts(speed: true, age: 7 * 86400 + 1).needsPrime(at: now))
    }
    func testTonightUsesPodTimezoneNineAMBoundaryAndDST() throws {
        func night(_ timestamp: String) throws -> DashboardNight {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
            return try XCTUnwrap(DashboardNight(timeline: .init(enabled: true, timezone: "America/Los_Angeles", now: date.timeIntervalSince1970 * 1000, jobs: [], occurrences: [])))
        }
        let before = try night("2026-11-01T16:59:00Z")
        XCTAssertEqual(before.end.timeIntervalSince(before.start), 17 * 3600)
        XCTAssertEqual(before.timeline.calendar.component(.day, from: before.start), 31)
        let after = try night("2026-11-01T17:00:00Z")
        XCTAssertEqual(after.timeline.calendar.component(.day, from: after.start), 1)
        XCTAssertEqual(after.end.timeIntervalSince(after.start), 16 * 3600)
        let spring = try night("2026-03-08T15:00:00Z")
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start), 15 * 3600)
    }
    func testTimelineKeepsPodEventsAndClearsTargetsAfterPowerOff() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T17:00:00Z"))
        let now = date.timeIntervalSince1970 * 1000
        let events: [SystemSchedulerTimeline.Occurrence] = [
            .init(id: "left-temp", type: "temperature", side: .left, at: now - 3_600_000, targetTempF: 72, brightness: nil),
            .init(id: "left-off", type: "power_off", side: .left, at: now + 3_600_000, targetTempF: nil, brightness: nil),
            .init(id: "alarm", type: "alarm", side: .right, at: now + 7200_000, targetTempF: nil, brightness: nil),
            .init(id: "prime", type: "prime", side: nil, at: now + 10_800_000, targetTempF: nil, brightness: nil),
            .init(id: "right-temp", type: "temperature", side: .right, at: now + 1000, targetTempF: 80, brightness: nil)
        ]
        let night = try XCTUnwrap(DashboardNight(timeline: .init(enabled: true, timezone: "UTC", now: now, jobs: [], occurrences: events)))
        XCTAssertEqual(night.target(side: .left, at: date), 72)
        XCTAssertNil(night.target(side: .left, at: date.addingTimeInterval(3600)))
        XCTAssertEqual(night.podEvents.map(\.id), ["alarm", "prime"])
        XCTAssertNil(night.nextTemperature(sides: [.left]))
        XCTAssertEqual(night.nextTemperature(sides: [.right])?.id, "right-temp")
        XCTAssertEqual(night.spans(side: .left).count, 1)
        XCTAssertEqual(night.spans(side: .left).first?.end, date.addingTimeInterval(3600))
    }
    func testPartialFailuresRetainValuesButInvalidateTheirFreshness() async {
        let client = DashboardFixtureClient()
        let workspace = SystemDashboardWorkspace(client: client, health: DemoSystemHealthClient(), thermal: DemoSystemThermalClient(), scheduler: DemoSystemSchedulerClient())
        let now = Date.now
        await workspace.refresh(now: now)
        XCTAssertNotNil(workspace.runtime)
        XCTAssertTrue(workspace.fresh("Runtime", now: now))
        XCTAssertFalse(workspace.fresh("Runtime", now: now.addingTimeInterval(91)))
        XCTAssertFalse(workspace.fresh("Thermal", now: now.addingTimeInterval(31)))
        await client.failRuntime()
        await workspace.refresh(details: true, now: now.addingTimeInterval(10))
        XCTAssertNotNil(workspace.runtime)
        XCTAssertFalse(workspace.fresh("Runtime", now: now.addingTimeInterval(10)))
        XCTAssertNotNil(workspace.errors["Runtime"])
        XCTAssertTrue(workspace.fresh("Maintenance", now: now.addingTimeInterval(10)))
        XCTAssertTrue(workspace.fresh("Thermal", now: now.addingTimeInterval(10)))
    }
    func testDetailedReadsAreThrottledIndependentlyFromLiveThermal() async {
        let client = DashboardFixtureClient()
        let workspace = SystemDashboardWorkspace(client: client, health: DemoSystemHealthClient(), thermal: DemoSystemThermalClient(), scheduler: DemoSystemSchedulerClient())
        let now = Date.now
        await workspace.refresh(now: now)
        await workspace.refresh(now: now.addingTimeInterval(10))
        let firstCount = await client.calls
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(workspace.receivedAt["Runtime"], now)
        XCTAssertEqual(workspace.receivedAt["Thermal"], now.addingTimeInterval(10))
        await workspace.refresh(now: now.addingTimeInterval(60))
        let secondCount = await client.calls
        XCTAssertEqual(secondCount, 2)
    }
}
private actor DashboardFixtureClient: SystemDashboardClient {
    private var failed = false
    private(set) var calls = 0
    func failRuntime() { failed = true }
    func runtime() throws -> SystemRuntimeFacts {
        calls += 1
        if failed { throw APIError.noBaseURL }
        return DemoSystemDashboardClient().runtime()
    }
    func maintenance() -> SystemMaintenanceFacts { DemoSystemDashboardClient().maintenance() }
}
