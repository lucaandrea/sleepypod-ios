import Foundation
import XCTest
@testable import Sleepypod

@MainActor
final class TemperatureParityTests: XCTestCase {
    private var savedCache: Data?
    override func setUp() async throws { savedCache = UserDefaults.standard.data(forKey: "cachedDeviceStatus") }
    override func tearDown() async throws { UserDefaults.standard.set(savedCache, forKey: "cachedDeviceStatus") }

    func testEightSleepMatchesWholeFahrenheitMappingAndClamp() {
        let expected = [55, 58, 61, 63, 66, 69, 72, 74, 77, 80, 83, 85, 88, 91, 94, 96, 99, 102, 105, 107, 110]
        for (index, fahrenheit) in expected.enumerated() {
            let level = index - 10
            XCTAssertEqual(TemperatureDisplay.fahrenheit(forLevel: level), fahrenheit)
            XCTAssertEqual(TemperatureDisplay.level(for: Double(fahrenheit)), level)
        }
        XCTAssertEqual(TemperatureDisplay.level(for: 82.5), 0)
        XCTAssertEqual(TemperatureDisplay.fahrenheit(forLevel: -50), 55)
        XCTAssertEqual(TemperatureDisplay.fahrenheit(forLevel: 50), 110)
        XCTAssertEqual(TemperatureDisplay.eightSleep.step(80, by: 1, unit: .celsius), 83)
        XCTAssertEqual(TemperatureDisplay.eightSleep.target(at: 0.5), 83)
    }

    func testOffsetAndSensorDegreesRemainIndependentOfDisplayUnit() {
        XCTAssertEqual(TemperatureDisplay.offset.text(68, unit: .celsius), "−12")
        XCTAssertEqual(TemperatureDisplay.offset.text(80, unit: .fahrenheit), "0")
        XCTAssertEqual(TemperatureDisplay.degrees.text(68, unit: .celsius, includeUnit: true), "20°C")
        XCTAssertEqual(TemperatureDisplay.degrees.step(68, by: 1, unit: .celsius), 70)
        XCTAssertEqual(TemperatureDisplay.degrees.step(110, by: 1, unit: .fahrenheit), 110)
        XCTAssertEqual(TemperatureDisplay.offset.target(at: -1), 55)
        XCTAssertEqual(TemperatureFormat.relative.degreeUnit, .fahrenheit)
    }

    func testCoreQueryValuesAreEncodedWithoutChangingParameters() throws {
        let client = CoreRESTClient(endpoint: URL(string: "https://example.invalid/controller")!)
        let request = try client.request("device/temperature/control", method: "GET", query: ["side": "left", "filter": "a&b + c"])
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/controller/api/device/temperature/control")
        XCTAssertEqual(components.queryItems?.count, 2)
        XCTAssertEqual(components.queryItems?.first { $0.name == "filter" }?.value, "a&b + c")
    }

    func testCoreHoldsAreExplicitAndLegacyPayloadDoesNotGainFields() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TemperatureRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SleepypodCoreClient(session: session, baseURL: URL(string: "https://temperature.test")!)
        try await client.updateDeviceStatus(DeviceStatusUpdate(left: SideStatusUpdate(targetTemperatureF: 68, holdMinutes: 120)))
        try await client.updateDeviceStatus(DeviceStatusUpdate(right: SideStatusUpdate(targetTemperatureF: 70)))
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SideStatusUpdate(targetTemperatureF: 68, holdMinutes: 120))) as? [String: Any]
        XCTAssertEqual(legacy?.count, 1)
        XCTAssertNil(legacy?["holdMinutes"])
    }

    func testManualHoldUsesMillisecondsAndSafetyTakesPriority() throws {
        let data = Data(#"{"source":"manual","requestId":"hold","targetTemperature":68,"holdUntil":1792962000000,"blocked":"safety"}"#.utf8)
        let status = try JSONDecoder().decode(TemperatureControlStatus.self, from: data)
        XCTAssertEqual(status.holdDate?.timeIntervalSince1970, 1792962000)
        XCTAssertEqual(status.title, "Safety stop")
    }

    func testTimelineUsesPodTimezoneAcrossDSTAndDoesNotInventUnknownTargets() {
        let now = ISO8601DateFormatter().date(from: "2026-03-07T22:00:00Z")!
        let timeline = TemperatureTimeline(schedules: nil, timezone: "America/Los_Angeles", now: now)
        XCTAssertEqual(timeline.range.upperBound.timeIntervalSince(timeline.range.lowerBound), 14 * 3600)
        XCTAssertNil(timeline.state(for: .left, at: timeline.date(at: 0.5)).temperature)
        XCTAssertNil(timeline.state(for: .left, at: timeline.date(at: 0.5)).powered)
        XCTAssertEqual(timeline.date(at: 2), timeline.range.upperBound)
    }

    func testTimelineCarriesOvernightPowerAndAppliesNextDaysSetpoint() async throws {
        var schedules = try await MockClient().getSchedules()
        for side in Side.allCases {
            var weekly = schedules.schedule(for: side)
            for day in DayOfWeek.allCases {
                weekly[day].temperatures = [:]
                weekly[day].power.enabled = false
            }
            schedules.setSchedule(weekly, for: side)
        }
        schedules.left.saturday.power = PowerSchedule(on: "22:00", off: "07:00", endAction: .turnOff, onTemperature: 72, enabled: true)
        schedules.left.sunday.temperatures = ["03:00": 68]
        let parse = ISO8601DateFormatter()
        let timeline = TemperatureTimeline(schedules: schedules, timezone: "America/Los_Angeles", now: parse.date(from: "2026-10-25T03:00:00Z")!)
        XCTAssertEqual(timeline.state(for: .left, at: parse.date(from: "2026-10-25T06:00:00Z")!), .init(temperature: 72, powered: true))
        XCTAssertEqual(timeline.state(for: .left, at: parse.date(from: "2026-10-25T11:00:00Z")!), .init(temperature: 68, powered: true))
        XCTAssertEqual(timeline.state(for: .left, at: parse.date(from: "2026-10-25T15:00:00Z")!), .init(temperature: 68, powered: false))
        let samplesAtChange = timeline.samples(for: .left).filter { $0.date == parse.date(from: "2026-10-25T10:00:00Z")! }
        XCTAssertEqual(samplesAtChange.map(\.temperature), [72, 68], "The chart must jump at 03:00, not before it")
    }

    func testAllOffDropsUnsentTemperatureAndDoesNotChangeLinkState() async throws {
        let client = RecordingTemperatureClient()
        let manager = DeviceManager(api: client)
        manager.acceptStatus(try await MockClient().getDeviceStatus())
        manager.setTemperature(68)
        manager.allOff()
        await manager.waitForCommands()
        let updates = await client.recorder.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.left?.isOn, false)
        XCTAssertEqual(updates.first?.right?.isOn, false)
        XCTAssertNil(updates.first?.left?.targetTemperatureF)
        XCTAssertFalse(manager.isLinked)
    }

    func testTimelineRespectsExplicitNextDayBoundaryAcrossDST() async throws {
        var schedules = try await MockClient().getSchedules()
        for day in DayOfWeek.allCases {
            schedules.left[day].power.enabled = false
            schedules.left[day].temperatures = [:]
        }
        schedules.left.saturday.power = PowerSchedule(on: "06:00", off: "07:00", endAction: .turnOff, offDayOffset: 1, onTemperature: 72, enabled: true)
        let parse = ISO8601DateFormatter()
        let timeline = TemperatureTimeline(schedules: schedules, timezone: "America/Los_Angeles", now: parse.date(from: "2026-03-08T03:00:00Z")!)
        XCTAssertEqual(timeline.state(for: .left, at: parse.date(from: "2026-03-08T12:00:00Z")!).powered, true)
        XCTAssertEqual(timeline.state(for: .left, at: parse.date(from: "2026-03-08T14:00:00Z")!).powered, false)
        schedules.left.saturday.power.endAction = .maintain
        let maintained = TemperatureTimeline(schedules: schedules, timezone: "America/Los_Angeles", now: parse.date(from: "2026-03-08T03:00:00Z")!)
        XCTAssertEqual(maintained.state(for: .left, at: parse.date(from: "2026-03-08T14:00:00Z")!).powered, true)
    }

    func testAllOffWaitsForInFlightTemperature() async throws {
        let client = RecordingTemperatureClient()
        await client.recorder.suspendFirst()
        let manager = DeviceManager(api: client)
        manager.acceptStatus(try await MockClient().getDeviceStatus())
        manager.setTemperature(68)
        await client.recorder.waitForFirst()
        manager.allOff()
        let pending = await client.recorder.updates
        XCTAssertEqual(pending.count, 1)
        await client.recorder.releaseFirst()
        await manager.waitForCommands()
        let updates = await client.recorder.updates
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].left?.targetTemperatureF, 68)
        XCTAssertEqual(updates[1].left?.isOn, false)
    }

    func testLinkingAloneDoesNotIssueHardwareCommands() async throws {
        let client = RecordingTemperatureClient()
        let manager = DeviceManager(api: client)
        manager.acceptStatus(try await MockClient().getDeviceStatus())
        manager.toggleLink()
        await manager.waitForCommands()
        let updates = await client.recorder.updates
        XCTAssertTrue(updates.isEmpty)
        XCTAssertEqual(manager.selectedSide, .both)
    }
}

private actor TemperatureRecorder {
    var updates: [DeviceStatusUpdate] = []
    private var suspend = false
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func suspendFirst() { suspend = true }
    func waitForFirst() async { if updates.isEmpty { await withCheckedContinuation { started = $0 } } }
    func releaseFirst() { release?.resume(); release = nil }
    func record(_ update: DeviceStatusUpdate) async {
        updates.append(update)
        started?.resume(); started = nil
        if suspend && updates.count == 1 { await withCheckedContinuation { release = $0 } }
    }
}
private final class RecordingTemperatureClient: MockAPIClient, @unchecked Sendable {
    let recorder = TemperatureRecorder()
    override func updateDeviceStatus(_ update: DeviceStatusUpdate) async throws { await recorder.record(update) }
}

private final class TemperatureRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(buffer, count: count)
            }
        }
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let input = envelope?["json"] as? [String: Any]
        let left = input?["side"] as? String == "left"
        let valid = request.url?.path == "/api/trpc/device.setTemperature" && request.httpMethod == "POST"
            && input?["temperature"] as? Int == (left ? 68 : 70)
            && input?["holdMinutes"] as? Int == (left ? 120 : 30)
        guard valid, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"result":{"data":{"json":{"success":true}}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
