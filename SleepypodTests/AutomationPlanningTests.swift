import XCTest
@testable import Sleepypod

@MainActor final class AutomationPlanningTests: XCTestCase {
    func testNightWindowsPreserveDSTAndCompoundUnknownConditions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(AutomationDates.parse("2026-11-01T03:00:00Z"))
        let timeline = AutomationTimeline(schedules: nil, rules: [], timezone: calendar.timeZone.identifier, now: now)
        XCTAssertEqual(timeline.range.upperBound.timeIntervalSince(timeline.range.lowerBound), 16 * 3600)
        let unknown = AutomationCondition.compare(operation: ">", left: .signal("left.movement"), right: .literal(5))
        let condition = AutomationCondition.all([.time(start: "23:00", end: "06:00"), .not(unknown)])
        let windows = AutomationTimeline.possibleWindows(condition, in: timeline.range, calendar: calendar)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.duration, 8 * 3600)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(windows.first?.start)), 23)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(windows.first?.end)), 6)
        XCTAssertNil(AutomationTimeline.temporalMatch(.not(unknown), at: now, calendar: calendar))
        XCTAssertEqual(AutomationTimeline.temporalMatch(.all([.any([]), unknown]), at: now, calendar: calendar), false)
        XCTAssertEqual(AutomationTimeline.temporalMatch(.any([.all([]), unknown]), at: now, calendar: calendar), true)
    }
    func testTimeAndDayRestrictionsUseEachActualPodCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let sundayMorning = try XCTUnwrap(AutomationDates.parse("2026-10-25T08:00:00Z"))
        XCTAssertEqual(AutomationTimeline.temporalMatch(.days([.sunday]), at: sundayMorning, calendar: calendar), true)
        XCTAssertEqual(AutomationTimeline.temporalMatch(.days([.saturday]), at: sundayMorning, calendar: calendar), false)
        XCTAssertEqual(AutomationTimeline.temporalMatch(.time(start: "01:00", end: "01:00"), at: sundayMorning, calendar: calendar), false)
        XCTAssertEqual(AutomationTimeline.temporalMatch(.time(start: "23:00", end: "06:00"), at: sundayMorning, calendar: calendar), true)
    }
    func testActionSideOverrideIsShownOnAffectedTimeline() {
        let rule = AutomationRule(id: 1, definition: .init(side: .left, actions: [.init(kind: .setPower, side: .right, on: false)]), createdAt: "", updatedAt: "")
        XCTAssertTrue(AutomationTimeline.affects(.right, rule: rule))
        XCTAssertFalse(AutomationTimeline.affects(.left, rule: rule))
    }
    func testReplayRangePayloadAndNullableSummaryKeepBothSideSemantics() throws {
        let request = AutomationRangeRequest(nights: 14, rule: .init(definition: .init(side: nil, cooldownMin: nil)))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["nights", "rule"])
        let rule = try XCTUnwrap(body["rule"] as? [String: Any])
        XCTAssertTrue(rule["side"] is NSNull); XCTAssertNil(rule["name"])
        let response = try JSONDecoder().decode(AutomationReplaySummary.self, from: Data(#"{"nights":5,"wouldFire":8,"peak":null,"low":null,"threshold":null}"#.utf8))
        XCTAssertNil(response.id); XCTAssertNil(response.peak)
        XCTAssertTrue(response.headline.contains("5 recorded nights")); XCTAssertFalse(response.headline.contains("10 recorded"))
    }
    func testRangeAndSavedSummaryRoutesAreReadOnlyReplayRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AutomationPlanningProtocol.self]
        let client = CoreAutomationClient(transport: .init(endpoint: URL(string: "https://automation-planning.invalid")!, session: .init(configuration: configuration)))
        let summaries = try await client.summaries(); XCTAssertEqual(summaries.first?.id, 19)
        let range = try await client.range(.init(side: nil), nights: 7); XCTAssertEqual(range.wouldFire, 8)
        do { _ = try await client.range(.init(), nights: 15); XCTFail("Invalid range must not be sent") } catch { XCTAssertTrue(error.localizedDescription.contains("1–14")) }
    }
    func testChangingRangeCountMarksPriorSummaryStale() async {
        let model = AutomationRangeWorkspace(client: DemoAutomationClient())
        let definition = AutomationDefinition()
        await model.run(definition); XCTAssertTrue(model.isCurrent(definition)); XCTAssertEqual(model.result?.nights, 0)
        model.nights = 6; XCTAssertFalse(model.isCurrent(definition))
    }
    func testSuppressionSpansMergeOnlyConsecutiveValidSamples() {
        XCTAssertEqual(AutomationReplaySpans.grouped([3, 1, 2, 3, 8, 9, -1, 99], count: 10), [1...3, 8...9])
        XCTAssertEqual(AutomationReplaySpans.grouped([], count: 0), [])
    }
    func testZoneScaleIsStableAcrossFramesAndPairsIgnoreReferenceChannels() {
        let replay = AutomationZoneReplay(ok: true, night: nil, frames: [
            .init(tMs: 1, zones: [0.1, 0.2, 0.3], peakZone: nil), .init(tMs: 2, zones: [0.1, 0.5, 0.2], peakZone: nil)
        ])
        XCTAssertEqual(replay.scale, 0.5)
        XCTAssertEqual(AutomationZoneReplay.liveZones([0.1, 0.3, 0.2, 0.4, 0.05, 0.2, 900, 900]), [Double(Float(0.3)), Double(Float(0.4)), Double(Float(0.2))])
        XCTAssertTrue(AutomationZoneReplay.liveZones([]).allSatisfy { $0.isNaN })
    }
    func testMissingActivityRecognizesCoreReasonWithoutCountingItAsSent() {
        let entry = AutomationActivity.Entry(ruleId: 1, ruleName: "Movement", outcome: "skipped", code: "signal-unavailable", start: 1, end: 2, count: 3, temp: nil, sides: [])
        XCTAssertTrue(AutomationActivityFilter.missing.matches(entry)); XCTAssertTrue(AutomationActivityFilter.skipped.matches(entry))
        XCTAssertFalse(AutomationActivityFilter.fired.matches(entry)); XCTAssertFalse(AutomationActivityFilter.wouldFire.matches(entry))
    }
}

private final class AutomationPlanningProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "automation-planning.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let summary = #"{"id":19,"nights":5,"wouldFire":8,"peak":80,"low":70,"threshold":76}"#
        var response = summary
        switch (request.httpMethod, url.path) {
        case ("GET", "/api/automations/backtest-summaries"): response = "[\(summary)]"
        case ("POST", "/api/automations/backtest-range"):
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096); var output = Data()
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; output.append(bytes, count: count) }
                data = output
            }
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            XCTAssertEqual(body?["nights"] as? Int, 7)
            XCTAssertTrue((body?["rule"] as? [String: Any])?["side"] is NSNull)
        default: XCTFail("Unexpected route; replay must not write rules or actuator state: \(request.httpMethod ?? "") \(url.path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
