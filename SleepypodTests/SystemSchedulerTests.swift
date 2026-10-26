import XCTest
@testable import Sleepypod

@MainActor final class SystemSchedulerTests: XCTestCase {
    func testNoonBoundariesUsePodTimezoneAcrossBothDSTTransitions() throws {
        for (now, hours) in [("2026-10-31T20:00:00-07:00", 25.0), ("2026-03-07T20:00:00-08:00", 23.0)] {
            let timeline = snapshot(now: date(now))
            let night = try XCTUnwrap(timeline.nights().first)
            XCTAssertEqual(night.end.timeIntervalSince(night.start) / 3600, hours)
            XCTAssertEqual(timeline.calendar.component(.hour, from: night.start), 12)
            XCTAssertEqual(timeline.calendar.component(.hour, from: night.end), 12)
            let axis = timeline.axis(for: night)
            XCTAssertEqual(timeline.calendar.component(.hour, from: axis.lowerBound), 17)
            XCTAssertEqual(timeline.calendar.component(.hour, from: axis.upperBound), 9)
        }
    }
    func testMorningBelongsToPreviousNightAndNoonBoundaryIsExclusive() throws {
        let morning = date("2026-11-01T08:00:00-08:00")
        let noon = date("2026-11-01T12:00:00-08:00")
        let timeline = snapshot(now: morning, occurrences: [event("at-noon", date: noon, type: "prime", side: nil)])
        let nights = timeline.nights()
        XCTAssertEqual(nights.count, 7)
        XCTAssertEqual(timeline.calendar.component(.day, from: nights[0].start), 31)
        XCTAssertTrue(nights[0].occurrences.isEmpty)
        XCTAssertEqual(nights[1].occurrences.count, 1)
    }
    func testNoInventedTargetBeforeFirstSetpointOrAfterPowerOffOrSessionEnd() throws {
        let start = date("2026-10-31T21:00:00-07:00")
        let records = [event("off", date: start.addingTimeInterval(3600), type: "power_off"), event("on", date: start, type: "power_on", target: 72)]
        XCTAssertNil(SystemSchedulerTimeline.heldTarget(records, side: .left, at: start.addingTimeInterval(-1)))
        XCTAssertEqual(SystemSchedulerTimeline.heldTarget(records, side: .left, at: start.addingTimeInterval(10)), 72)
        XCTAssertNil(SystemSchedulerTimeline.heldTarget(records, side: .right, at: start.addingTimeInterval(10)))
        XCTAssertNil(SystemSchedulerTimeline.heldTarget(records, side: .left, at: start.addingTimeInterval(3600)))
        let simultaneous = [event("set", date: start, type: "temperature", target: 70), event("off", date: start, type: "power_off")]
        XCTAssertNil(SystemSchedulerTimeline.heldTarget(Array(simultaneous.reversed()), side: .left, at: start))
        let ended = [event("set", date: start, type: "run_once", target: 70), event("end", date: start.addingTimeInterval(1), type: "run_once")]
        XCTAssertNil(SystemSchedulerTimeline.heldTarget(ended, side: .left, at: start.addingTimeInterval(2)))
    }
    func testChartKeepsMaintenanceOutsideAxisAndExpandsForEarlySideJobs() throws {
        let now = date("2026-10-31T18:00:00-07:00")
        let prime = event("prime", date: date("2026-10-31T14:00:00-07:00"), type: "prime", side: nil)
        var timeline = snapshot(now: now, occurrences: [prime])
        var night = try XCTUnwrap(timeline.nights().first)
        XCTAssertEqual(timeline.calendar.component(.hour, from: timeline.axis(for: night).lowerBound), 17)
        let early = event("early", date: date("2026-10-31T15:30:00-07:00"), type: "temperature", target: 73)
        timeline = snapshot(now: now, occurrences: [prime, early]); night = try XCTUnwrap(timeline.nights().first)
        let range = timeline.axis(for: night)
        XCTAssertEqual(timeline.calendar.component(.hour, from: range.lowerBound), 15)
        XCTAssertEqual(SystemSchedulerTimeline.targetSpans(night, side: .left, range: range).first?.start, early.date)
        XCTAssertEqual(night.occurrences.count, 2)
    }
    func testRecurringOccurrenceIdentityAndUnknownTypesArePreserved() throws {
        let timeline = try DemoSystemSchedulerClient().timeline()
        XCTAssertGreaterThan(timeline.occurrences.count, timeline.jobs.count)
        XCTAssertEqual(Set(timeline.occurrences.map(\.identity)).count, timeline.occurrences.count)
        let grouped = SystemSchedulerTimeline.Group.allCases.reduce(0) { count, group in count + timeline.jobs.filter { $0.group == group }.count }
        XCTAssertEqual(grouped, timeline.jobs.count)
        XCTAssertEqual(SystemSchedulerTimeline.Group(type: "future_job"), .other)
        XCTAssertEqual(SystemSchedulerTimeline.label("wake_window"), "Wake Window")
    }
    func testRecurrenceRecognizesSimpleCronAndPreservesUnsupportedExpressions() throws {
        let timeline = snapshot(now: .now)
        XCTAssertTrue(timeline.recurrence(job("30 23 * * *")).hasPrefix("Daily"))
        XCTAssertTrue(timeline.recurrence(job("30 23 * * 1,3,7")).hasPrefix("Mon, Wed, Sun"))
        for schedule in ["99 23 * * *", "0 24 * * *", "0 5 * * 1-5", "*/10 * * * *", "0 5 * * ,"] {
            XCTAssertEqual(timeline.recurrence(job(schedule)), schedule)
        }
        XCTAssertTrue(timeline.recurrence(job("2026-11-01T06:30:00.000Z", once: true)).hasPrefix("Once"))
        XCTAssertEqual(timeline.recurrence(job("not-a-date", once: true)), "not-a-date")
    }
    func testTransportRequestsEightDaysAndNeverMutatesSchedules() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SchedulerFixtureProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreSystemSchedulerClient(transport: .init(endpoint: URL(string: "https://scheduler-test.invalid")!, session: session))
        let timeline = try await client.timeline(); let health = try await client.health()
        XCTAssertEqual(timeline.timezone, "America/Los_Angeles"); XCTAssertFalse(timeline.enabled)
        XCTAssertNil(health.scheduler.drift)
    }
    func testFailedRefreshKeepsLabeledTimelineButClearsStaleHealth() async {
        let client = ChangingSchedulerClient()
        let workspace = SystemSchedulerWorkspace(client: client)
        await workspace.load(); XCTAssertNotNil(workspace.timeline); XCTAssertNotNil(workspace.health)
        await client.fail()
        await workspace.load()
        XCTAssertNotNil(workspace.timeline); XCTAssertNotNil(workspace.error)
        XCTAssertNil(workspace.health); XCTAssertNotNil(workspace.healthError)
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func snapshot(now: Date, occurrences: [SystemSchedulerTimeline.Occurrence] = []) -> SystemSchedulerTimeline {
        .init(enabled: true, timezone: "America/Los_Angeles", now: now.timeIntervalSince1970 * 1000, jobs: [], occurrences: occurrences)
    }
    private func event(_ id: String, date: Date, type: String, side: Side? = .left, target: Double? = nil) -> SystemSchedulerTimeline.Occurrence {
        .init(id: id, type: type, side: side, at: date.timeIntervalSince1970 * 1000, targetTempF: target, brightness: nil)
    }
    private func job(_ schedule: String, once: Bool = false) -> SystemSchedulerTimeline.Job {
        .init(id: "test", type: "temperature", side: .left, schedule: schedule, oneTime: once, nextRun: nil, targetTempF: nil, brightness: nil)
    }
}

private actor ChangingSchedulerClient: SystemSchedulerClient {
    private var failing = false
    func fail() { failing = true }
    func timeline() throws -> SystemSchedulerTimeline {
        if failing { throw APIError.noBaseURL }
        return .init(enabled: true, timezone: "UTC", now: 0, jobs: [], occurrences: [])
    }
    func health() throws -> SystemSchedulerHealth {
        if failing { throw APIError.noBaseURL }
        return .init(scheduler: .init(enabled: true, jobCount: 0, drift: nil))
    }
}

private final class SchedulerFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "scheduler-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        let body: String
        if url.path == "/api/health/scheduler-timeline" {
            XCTAssertEqual(url.query, "days=8")
            body = #"{"enabled":false,"timezone":"America/Los_Angeles","now":1792900000000,"jobs":[],"occurrences":[]}"#
        } else {
            XCTAssertEqual(url.path, "/api/health/system")
            body = #"{"scheduler":{"enabled":false,"jobCount":0}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
