import AppIntents
import Foundation
import Testing
@testable import FreeSleepKit

struct ShortcutTests {
    @Test func controlIntentsSendOnlyRequestedFieldsAndUseTheChosenSide() async throws {
        let fixture = try IntentHTTPFixture(); defer { fixture.close() }
        try await PodActions.$suppliedClient.withValue(fixture.client) {
            let temperature = SetTemperatureIntent(); temperature.side = .right; temperature.temperature = 78
            _ = try await temperature.perform()
            let power = SetPowerIntent(); power.side = .left; power.enabled = false
            _ = try await power.perform()
            let preset = SetBasePresetIntent(); preset.preset = .read
            _ = try await preset.perform()
            let angles = SetBaseAnglesIntent(); angles.head = 21; angles.feet = 12
            _ = try await angles.perform()
            _ = try await StopBaseIntent().perform()
            _ = try await PrimePodIntent().perform()
            let dismiss = DismissAlarmIntent(); dismiss.side = .right
            _ = try await dismiss.perform()
            let away = SetAwayModeIntent(); away.side = .left; away.away = true
            _ = try await away.perform()
            let comfort = SetComfortIntent(); comfort.side = .right; comfort.mode = .preview
            _ = try await comfort.perform()
        }
        #expect(fixture.requests.count == 9)
        try fixture.expect(0, path: "deviceStatus", body: ["right": ["targetTemperatureF": 78]])
        try fixture.expect(1, path: "deviceStatus", body: ["left": ["isOn": false]])
        try fixture.expect(2, path: "base/preset", body: ["preset": "read"])
        try fixture.expect(3, path: "base/position", body: ["head": 21, "feet": 12, "speed": 50])
        try fixture.expect(4, path: "base/stop", body: [:])
        try fixture.expect(5, path: "deviceStatus", body: ["isPriming": true])
        try fixture.expect(6, path: "deviceStatus", body: ["right": ["isAlarmVibrating": false]])
        try fixture.expect(7, path: "settings", body: ["left": ["awayMode": true]])
        // This must remain one mode-only write. A GET followed by writing limits can overwrite another client's newer limits.
        try fixture.expect(8, path: "comfort/mode", body: ["side": "right", "mode": "preview"])
    }

    @Test func invalidPhysicalTargetsNeverReachTheTransport() async throws {
        let fixture = try IntentHTTPFixture(); defer { fixture.close() }
        await PodActions.$suppliedClient.withValue(fixture.client) {
            for value in [Double.nan, .infinity, 54, 111] {
                let intent = SetTemperatureIntent(); intent.temperature = value; intent.side = .left
                await failure(containing: "55 to 110") { _ = try await intent.perform() }
            }
            for (head, feet) in [(-1, 0), (61, 0), (0, -1), (0, 46)] {
                let intent = SetBaseAnglesIntent(); intent.head = head; intent.feet = feet
                await failure(containing: "0–60") { _ = try await intent.perform() }
            }
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test func readIntentsReturnComposableValuesFromTheRequestedSide() async throws {
        let analytics = try #require(SleepDemo.shared?.analytics)
        let data = try JSONEncoder().encode(analytics)
        let fixture = try IntentHTTPFixture { request in
            if request.url?.path == "/api/analytics" { return .init(data: data) }
            return .init(status: 200, json: #"{"left":{"currentTemperatureF":61,"targetTemperatureF":82,"isOn":true},"right":{"currentTemperatureF":62,"targetTemperatureF":83,"isOn":false},"isPriming":false,"waterLevel":"full"}"#)
        }; defer { fixture.close() }
        try await PodActions.$suppliedClient.withValue(fixture.client) {
            for (side, reading, expected): (BedSide, TemperatureReading, Double) in [(.left, .current, 61), (.left, .target, 82), (.right, .current, 62), (.right, .target, 83)] {
                let intent = GetTemperatureIntent(); intent.side = side; intent.reading = reading
                #expect(try await intent.perform().value == expected)
            }
            let summary = SleepSummaryIntent(); summary.side = .right
            let text = try #require(try await summary.perform().value)
            #expect(text.contains("\(analytics.summary.recordedNights) recorded nights"))
            #expect(text.contains("Presence is not measured sleep"))
        }
        for index in 0..<4 { try fixture.expect(index, method: "GET", path: "deviceStatus") }
        try fixture.expect(4, method: "GET", path: "analytics", query: "side=right")
    }

    @Test func alarmIntentsPreserveOccurrenceAndRestoreIdentity() async throws {
        let fixture = try IntentHTTPFixture { _ in .init(status: 200, json: Self.alarm) }; defer { fixture.close() }
        try await PodActions.$suppliedClient.withValue(fixture.client) {
            let read = GetNextAlarmIntent(); read.side = .right
            #expect(try await read.perform().value?.contains("Europe/London") == true)
            let change = ChangeNextAlarmIntent(); change.side = .right; change.time = "21:15"
            _ = try await change.perform()
            let skip = SkipNextAlarmIntent(); skip.side = .right
            _ = try await skip.perform()
            let restore = RestoreAlarmRoutineIntent(); restore.side = .right
            _ = try await restore.perform()
        }
        #expect(fixture.requests.count == 7)
        for index in [0, 1, 3, 5] { try fixture.expect(index, method: "GET", path: "alarm/next", query: "side=right") }
        var expected = ["side": "right", "expectedAt": "2026-10-15T06:00:00.000Z"]
        expected["action"] = "time"; expected["time"] = "21:15"
        try fixture.expect(2, path: "alarm/override", body: expected)
        expected["action"] = "disable"; expected.removeValue(forKey: "time")
        try fixture.expect(4, path: "alarm/override", body: expected)
        expected = ["side": "right", "action": "restore", "expectedExpiresAt": "2026-10-15T06:02:00.000Z", "expectedRevision": "fixture-revision"]
        try fixture.expect(6, path: "alarm/override", body: expected)
    }

    @Test func mismatchedAlarmSideAndInvalidClockCannotWriteAnotherSide() async throws {
        let fixture = try IntentHTTPFixture { _ in .init(status: 200, json: Self.alarm) }; defer { fixture.close() }
        await PodActions.$suppliedClient.withValue(fixture.client) {
            let read = GetNextAlarmIntent(); read.side = .left
            await failure(containing: "different side") { _ = try await read.perform() }
            let skip = SkipNextAlarmIntent(); skip.side = .left
            await failure(containing: "different side") { _ = try await skip.perform() }
            let change = ChangeNextAlarmIntent(); change.side = .right; change.time = "7 PM"
            await failure(containing: "24-hour") { _ = try await change.perform() }
        }
        #expect(fixture.requests.count == 3)
        #expect(fixture.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func serverAndTransportFailuresAreReturnedWithoutRetryingCommands() async throws {
        for (status, message) in [(401, "token"), (403, "token"), (503, "unavailable"), (409, "stale action"), (404, "stale action"), (502, "stale action")] {
            let fixture = try IntentHTTPFixture { _ in .init(status: status, json: #"{"error":{"message":"stale action"}}"#) }
            await PodActions.$suppliedClient.withValue(fixture.client) {
                let intent = SetComfortIntent(); intent.side = .left; intent.mode = .active
                await failure(containing: message) { _ = try await intent.perform() }
            }
            #expect(fixture.requests.count == 1); fixture.close()
        }
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cancelled] {
            let fixture = try IntentHTTPFixture { _ in throw URLError(code) }
            await PodActions.$suppliedClient.withValue(fixture.client) {
                await failure { _ = try await StopBaseIntent().perform() }
            }
            #expect(fixture.requests.count == 1); fixture.close()
        }
        let broken = try IntentHTTPFixture { _ in .init(status: 200, json: "not JSON") }; defer { broken.close() }
        await PodActions.$suppliedClient.withValue(broken.client) {
            let intent = GetTemperatureIntent(); intent.side = .left; intent.reading = .current
            await failure { _ = try await intent.perform() }
        }
        #expect(broken.requests.count == 1)
    }

    @Test func concurrentActionScopesKeepClientsAndCredentialsSeparate() async throws {
        let first = try IntentHTTPFixture(token: "first-fixture"); defer { first.close() }
        let second = try IntentHTTPFixture(token: "second-fixture", apiPrefix: "native/v1"); defer { second.close() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for fixture in [first, second] {
                group.addTask {
                    try await PodActions.$suppliedClient.withValue(fixture.client) {
                        _ = try await StopBaseIntent().perform()
                    }
                }
            }
            try await group.waitForAll()
        }
        try first.expect(0, path: "base/stop", body: [:], token: "first-fixture")
        try second.expect(0, path: "native/v1/base/stop", body: [:], token: "second-fixture")
        #expect(first.requests.count == 1); #expect(second.requests.count == 1)
        #expect(PodActions.suppliedClient == nil)
    }

    @Test func missingCoreCompatibilityReportsUnavailableWithoutRetrying() async throws {
        let fixture = try IntentHTTPFixture(apiPrefix: "native/v1") { _ in .init(status: 404) }
        defer { fixture.close() }
        await failure(containing: "has not enabled this feature service") {
            try await fixture.client.action("base/stop")
        }
        #expect(fixture.requests.count == 1)
        try fixture.expect(0, path: "native/v1/base/stop", body: [:])
    }

    private static let alarm = #"{"side":"right","timeZone":"Europe/London","state":"scheduled","alarm":{"at":"2026-10-15T06:00:00.000Z","time":"07:00","scheduleDay":"wednesday","source":"routine"},"expiresAt":"2026-10-15T06:02:00.000Z","overrideRevision":"fixture-revision"}"#
    private func failure(containing text: String? = nil, operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("The action unexpectedly succeeded") }
        catch { if let text { #expect(error.localizedDescription.contains(text)) } }
    }
}
