import XCTest
@testable import Sleepypod

@MainActor final class BedroomContextTests: XCTestCase {
    private func fixture() throws -> BedroomStatus {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "bedroom-context-core", withExtension: "json"))
        return try JSONDecoder().decode(BedroomStatus.self, from: Data(contentsOf: url))
    }
    private func workspace(_ client: BedroomMemoryClient, clock: BedroomClock) -> BedroomWorkspace {
        let model = BedroomWorkspace(client: client, now: { clock.date }); model.isActive = true; return model
    }
    func testCoreFixtureDecodesFiveDevicesAndKeepsCachedParticlesOutOfControl() throws {
        let status = try fixture(); try status.validate()
        XCTAssertEqual(Set(status.config.sources.map(\.deviceId)).count, 5)
        XCTAssertEqual(status.guidance.offsetF, -1)
        XCTAssertEqual(status.guidance.state, "ready")
        let monitor = try XCTUnwrap(status.observations.first { $0.id == "monitor-particles" })
        XCTAssertEqual(monitor.status, .cached); XCTAssertNil(monitor.value); XCTAssertFalse(monitor.controlEligible)
    }
    func testReceiptExpiryServerClockOffsetAndForegroundBoundary() async throws {
        let clock = BedroomClock(); let model = workspace(BedroomMemoryClient(try fixture()), clock: clock)
        await model.refresh()
        let item = try XCTUnwrap(model.status?.observations.first)
        XCTAssertEqual(model.value(item, at: clock.date), 76)
        XCTAssertEqual(model.aggregate(.humidity, at: clock.date), 50)
        clock.date.addTimeInterval(15)
        XCTAssertNil(model.value(item, at: clock.date)); XCTAssertNil(model.aggregate(.humidity, at: clock.date)); XCTAssertNil(model.guidance(at: clock.date))
        await model.refresh(); model.isActive = false
        XCTAssertNil(model.value(item, at: clock.date))
        model.isActive = true; clock.date.addTimeInterval(-1)
        XCTAssertNil(model.serverTime(at: clock.date))
    }
    func testSourceExpiresBetweenSuccessfulPollsAndCachedReportStaysUnavailable() async throws {
        let status = try changing(fixture()) { payload in
            let generated = payload["generatedAt"] as! Int64
            var rows = payload["observations"] as! [[String: Any]]
            for index in rows.indices where rows[index]["status"] as? String == "fresh" { rows[index]["expiresAt"] = generated + 1_000 }
            payload["observations"] = rows
            var aggregates = payload["aggregates"] as! [[String: Any]]
            for index in aggregates.indices where aggregates[index]["status"] as? String == "ready" { aggregates[index]["expiresAt"] = generated + 1_000 }
            payload["aggregates"] = aggregates
            var guidance = payload["guidance"] as! [String: Any]; guidance["expiresAt"] = generated + 1_000; payload["guidance"] = guidance
        }
        let clock = BedroomClock(); let model = workspace(BedroomMemoryClient(status), clock: clock); await model.refresh()
        XCTAssertNotNil(model.guidance(at: clock.date))
        let monitor = try XCTUnwrap(model.status?.observations.first { $0.id == "monitor-particles" })
        XCTAssertNil(model.value(monitor, at: clock.date))
        clock.date.addTimeInterval(2)
        XCTAssertNil(model.aggregate(.temperature, at: clock.date)); XCTAssertNil(model.guidance(at: clock.date))
        XCTAssertNotNil(model.serverTime(at: clock.date))
    }
    func testCachedValueIsVisibleAsAReportWithoutBecomingCurrentOrEligibleForControl() async throws {
        let clock = BedroomClock(); let model = workspace(BedroomMemoryClient(try fixture()), clock: clock)
        await model.refresh()
        let item = try XCTUnwrap(model.status?.observations.first { $0.id == "monitor-particles" })
        XCTAssertNil(model.value(item, at: clock.date))
        XCTAssertEqual(model.lastReportedValue(item), 1)
        XCTAssertEqual(model.readingStatus(item, at: clock.date), "Cached report · freshness unknown")
        XCTAssertFalse(item.controlEligible)
        clock.date.addTimeInterval(15)
        XCTAssertNil(model.value(item, at: clock.date))
        XCTAssertEqual(model.lastReportedValue(item), 1)
        XCTAssertEqual(model.readingStatus(item, at: clock.date), "Last reported · reconnect to refresh")
        model.isActive = false
        XCTAssertNil(model.lastReportedValue(item))
    }
    func testExpiredMeasurementRemainsOnlyAnExplicitHistoricalReport() async throws {
        let status = try changing(fixture()) { payload in
            let generated = payload["generatedAt"] as! Int64
            var rows = payload["observations"] as! [[String: Any]]
            rows[0]["expiresAt"] = generated + 1_000
            payload["observations"] = rows
            payload["aggregates"] = []
            payload["guidance"] = ["state": "unavailable", "offsetF": 0, "reason": "Fixture", "sourceIds": []]
        }
        let clock = BedroomClock(); let model = workspace(BedroomMemoryClient(status), clock: clock)
        await model.refresh()
        let item = try XCTUnwrap(model.status?.observations.first)
        clock.date.addTimeInterval(2)
        XCTAssertNil(model.value(item, at: clock.date))
        XCTAssertEqual(model.lastReportedValue(item), 76)
        XCTAssertEqual(model.readingStatus(item, at: clock.date), "Last reported · expired")
        XCTAssertNil(model.guidance(at: clock.date))
    }
    func testWaitingHomePodDoesNotInventValuesAndExplainsItsMissingExport() async throws {
        let status = try changing(fixture()) { payload in
            var rows = payload["observations"] as! [[String: Any]]
            for index in rows.indices {
                rows[index]["status"] = "waiting"
                rows[index]["controlEligible"] = false
                for key in ["value", "lastValue", "observedAt", "measuredAt", "receivedAt", "expiresAt", "timeBasis"] { rows[index][key] = NSNull() }
            }
            payload["observations"] = rows
            payload["aggregates"] = []
            payload["guidance"] = ["state": "unavailable", "offsetF": 0, "reason": "Fixture", "sourceIds": []]
        }
        let clock = BedroomClock(); let model = workspace(BedroomMemoryClient(status), clock: clock)
        await model.refresh()
        let item = try XCTUnwrap(model.status?.observations.first)
        XCTAssertNil(model.value(item, at: clock.date))
        XCTAssertNil(model.lastReportedValue(item))
        XCTAssertEqual(model.readingStatus(item, at: clock.date), "Apple Home sensor export not connected")
    }
    func testDisplayOnlyZeroAndTemperatureUnitsRemainVisible() async throws {
        let clock = BedroomClock(); let model = workspace(BedroomMemoryClient(try fixture()), clock: clock)
        await model.refresh()
        let item = try XCTUnwrap(model.status?.observations.first { $0.id == "diffuser-power" })
        XCTAssertEqual(model.value(item, at: clock.date), 0)
        XCTAssertEqual(model.readingStatus(item, at: clock.date), "Current · display only")
        XCTAssertEqual(BedroomDeviceReadings.formatted(0, metric: .power, celsius: false), "Off")
        XCTAssertEqual(BedroomDeviceReadings.formatted(68, metric: .temperature, celsius: true), "20 °C")
        XCTAssertEqual(BedroomDeviceReadings.formatted(nil, metric: .temperature, celsius: true), "—")
    }
    func testRestartKeepsHistoricalReportSeparateFromWaitingSource() async throws {
        let status = try changing(fixture()) { payload in
            var rows = payload["observations"] as! [[String: Any]]
            for index in rows.indices {
                rows[index]["status"] = "waiting"; rows[index]["value"] = NSNull(); rows[index]["controlEligible"] = false
            }
            payload["observations"] = rows; payload["aggregates"] = []
            payload["guidance"] = ["state": "unavailable", "offsetF": 0, "reason": "Fixture", "sourceIds": []]
        }
        let clock = BedroomClock(); let model = workspace(BedroomMemoryClient(status), clock: clock)
        await model.refresh()
        let item = try XCTUnwrap(model.status?.observations.first)
        XCTAssertNil(model.value(item, at: clock.date))
        XCTAssertEqual(model.lastReportedValue(item), 76)
        XCTAssertEqual(model.readingStatus(item, at: clock.date), "Last reported · waiting for a new update")
        XCTAssertNil(model.guidance(at: clock.date))
    }
    func testFailureWithdrawsValuesWhileKeepingDeviceInventory() async throws {
        let clock = BedroomClock(); let client = BedroomMemoryClient(try fixture()); let model = workspace(client, clock: clock)
        await model.refresh(); await client.fail(); await model.refresh()
        XCTAssertNotNil(model.status); XCTAssertNotNil(model.error)
        XCTAssertNil(model.aggregate(.temperature, at: clock.date)); XCTAssertNil(model.guidance(at: clock.date))
    }
    func testRevisionConflictAndInactiveOwnerPreventConfigurationWrites() async throws {
        let clock = BedroomClock(); let client = BedroomMemoryClient(try fixture()); let model = workspace(client, clock: clock); await model.refresh()
        let original = try XCTUnwrap(model.status?.version)
        let wrong = BedroomVersion(revision: original.revision - 1, config: original.config)
        let conflicted = await model.save(original.config, original: wrong); XCTAssertFalse(conflicted)
        model.isActive = false
        let inactive = await model.save(original.config, original: original); XCTAssertFalse(inactive)
        let count = await client.saveCount; XCTAssertEqual(count, 0)
    }
    func testLostConfigurationReplyReadsBackWithoutRepeatingTheWrite() async throws {
        let clock = BedroomClock(); let client = BedroomMemoryClient(try fixture()); let model = workspace(client, clock: clock); await model.refresh()
        let original = try XCTUnwrap(model.status?.version); var config = original.config; config.roomName = "Changed fixture name"
        await client.dropReply()
        let saved = await model.save(config, original: original); XCTAssertFalse(saved)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.receivedAt)
        await model.refresh()
        XCTAssertNil(model.pending); XCTAssertEqual(model.status?.config.roomName, config.roomName)
        let count = await client.saveCount; XCTAssertEqual(count, 1)
    }
    func testDuplicateSourcesAndForgedCurrentReadingsAreRejected() throws {
        var config = try fixture().config; config.sources.append(config.sources[0]); XCTAssertThrowsError(try config.validate())
        let forged = try changing(fixture()) { payload in
            var rows = payload["observations"] as! [[String: Any]]
            rows[0]["timeBasis"] = "cached"; payload["observations"] = rows
        }
        XCTAssertThrowsError(try forged.validate())
        let future = try changing(fixture()) { payload in
            var rows = payload["observations"] as! [[String: Any]]
            rows[0]["observedAt"] = (payload["generatedAt"] as! Int64) + 1; payload["observations"] = rows
        }
        XCTAssertThrowsError(try future.validate())
    }
    func testRoomAwareSettingSurvivesNativeDecodeEditEncode() throws {
        let data = Data(#"{"mode":"preview","minimumF":70,"maximumF":95,"sensorAware":true,"roomAware":true}"#.utf8)
        var config = try JSONDecoder().decode(PersonalComfortConfig.self, from: data)
        config.maximumF = 94
        let result = try JSONDecoder().decode(PersonalComfortConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(result.roomAware, true)
        let legacy = try JSONDecoder().decode(PersonalComfortConfig.self, from: Data(#"{"mode":"off","minimumF":70,"maximumF":95}"#.utf8))
        XCTAssertNil(legacy.roomAware)
    }
    func testFreshReadingsRequireReportingClockAndCannotExtendTheirSourceLease() throws {
        for observed: Any in [NSNull(), Int64(1)] {
            let malformed = try changing(fixture()) { payload in
                var rows = payload["observations"] as! [[String: Any]]
                rows[0]["observedAt"] = observed; payload["observations"] = rows
            }
            XCTAssertThrowsError(try malformed.validate())
        }
    }
    func testOwnerQualificationIdentityIncludesRoomSelectionAndOptIn() throws {
        let digest = String(repeating: "a", count: 64)
        var identity = ComfortOwnerIdentity(hardware: digest, calibration: digest, schedule: digest, build: "82ec540",
                                             policy: .init(minimumF: 70, maximumF: 95, sensorAware: true, followBedtime: false, roomAware: true))
        XCTAssertFalse(identity.valid)
        identity.bedroomConfiguration = digest
        XCTAssertTrue(identity.valid)
        var changed = identity; changed.bedroomConfiguration = String(repeating: "b", count: 64)
        XCTAssertNotEqual(identity, changed)
        let roundTrip = try JSONDecoder().decode(ComfortOwnerIdentity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(roundTrip, identity)
    }
    private func changing(_ status: BedroomStatus, edit: (inout [String: Any]) -> Void) throws -> BedroomStatus {
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        edit(&payload)
        return try JSONDecoder().decode(BedroomStatus.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

@MainActor private final class BedroomClock { var date = Date(timeIntervalSince1970: 1000) }
private actor BedroomMemoryClient: BedroomServing {
    var value: BedroomStatus
    var failing = false
    var dropping = false
    private(set) var saveCount = 0
    init(_ value: BedroomStatus) { self.value = value }
    func fail() { failing = true }
    func dropReply() { dropping = true }
    func status() throws -> BedroomStatus { if failing { throw URLError(.cannotConnectToHost) }; return value }
    func configure(_ config: BedroomConfiguration, expectedRevision: Int64) throws -> BedroomVersion {
        saveCount += 1
        guard expectedRevision == value.revision else { throw BedroomStatus.issue }
        value = .init(apiVersion: value.apiVersion, generatedAt: value.generatedAt, revision: value.revision + 1, config: config,
                      observations: value.observations, aggregates: value.aggregates, guidance: value.guidance, mqtt: value.mqtt)
        if dropping { throw URLError(.networkConnectionLost) }
        return value.version
    }
}
