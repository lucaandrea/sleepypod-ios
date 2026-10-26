import XCTest
@testable import Sleepypod

@MainActor final class SensorDiagnosticsTests: XCTestCase {
    func testFreezerWireUnitsMissingBranchesAndThermalDialects() throws {
        let temperature = Data(#"{"type":"frzTemp","ts":1000,"left":2145,"right":-32768,"amb":2350,"hs":null}"#.utf8)
        guard case .frzTemp(let frame) = SensorFrame.decode(from: temperature) else { return XCTFail("Missing freezer frame") }
        XCTAssertEqual(frame.reading.leftWaterTemp, 21.45)
        XCTAssertNil(frame.reading.rightWaterTemp)
        XCTAssertNil(frame.reading.heatsinkTemp)
        let health = Data(#"{"type":"frzHealth","ts":1000,"left":{"temps":{"flowrate":24.5}},"right":{},"fan":{"top":{}}}"#.utf8)
        guard case .frzHealth(let decoded) = SensorFrame.decode(from: health) else { return XCTFail("Partial health must decode") }
        XCTAssertEqual(decoded.left?.temps?.flowrate, 24.5)
        XCTAssertNil(decoded.left?.pump?.rpm)
        XCTAssertNil(decoded.right?.tec?.current)
        XCTAssertNil(decoded.fan?.top?.rpm)
        let thermal = Data(#"{"type":"frzTherm","ts":1000,"left":{"power":15,"target":2100,"valid":false,"enabled":true},"right":-10}"#.utf8)
        guard case .frzTherm(let control) = SensorFrame.decode(from: thermal) else { return XCTFail("Thermal dialects must decode") }
        XCTAssertEqual(control.left?.power, 15)
        XCTAssertEqual(control.left?.valid, false)
        XCTAssertEqual(control.right?.power, -10)
        XCTAssertNil(control.right?.valid)
    }
    func testSnapshotsRetainMeasurementAgeRejectRegressionAndFutureReadings() {
        let stream = SensorStreamService()
        let now = Date(timeIntervalSince1970: 2000)
        stream.handleFrame(Data(#"{"type":"snapshot","latest":[{"type":"bedTemp2","ts":1000,"left":{"temps":[21,22,23]},"right":{"temps":[24,25,26]}}],"waveform":[]}"#.utf8), receivedAt: now)
        XCTAssertEqual(stream.bedTempUpdatedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(stream.lastFrameTime, now)
        XCTAssertFalse(SensorObservation.fresh(stream.bedTempUpdatedAt, now: now))
        stream.handleFrame(Data(#"{"type":"bedTemp2","ts":900,"left":{"temps":[1]},"right":{"temps":[1]}}"#.utf8), receivedAt: now)
        XCTAssertEqual(stream.leftTemps?.temps.first, 21)
        stream.handleFrame(Data(#"{"type":"bedTemp","ts":950,"left":{"temps":[100]},"right":{"temps":[100]}}"#.utf8), receivedAt: now)
        XCTAssertEqual(stream.leftTemps?.temps.first, 21, "An older firmware dialect must not supersede a newer observation")
        stream.handleFrame(Data(#"{"type":"bedTemp2","ts":3000,"left":{"temps":[2]},"right":{"temps":[2]}}"#.utf8), receivedAt: now)
        XCTAssertEqual(stream.leftTemps?.temps.first, 21)
        stream.disconnect()
        XCTAssertNil(stream.leftTemps)
        XCTAssertNil(stream.bedTempUpdatedAt)
        XCTAssertTrue(stream.calibrationSignals.temperature.isEmpty)
    }
    func testLateOccupancyCannotPopulateDisconnectedController() async {
        let stream = SensorStreamService(), client = SensorFixtureClient()
        await client.delayOccupancy()
        let task = Task { await stream.refreshOccupancy(client: client) }
        await client.waitForOccupancy()
        stream.disconnect()
        await client.releaseOccupancy()
        await task.value
        XCTAssertNil(stream.occupancy)
        XCTAssertNil(stream.occupancyUpdatedAt)
    }
    func testPresenceIsControllerReportedAndFailureNeverBecomesEmpty() async {
        let stream = SensorStreamService(), client = SensorFixtureClient()
        stream.leftVariance = [100, 100, 100]
        XCTAssertEqual(stream.presenceLabel(sides: [.left]), "PRESENCE UNKNOWN")
        await stream.refreshOccupancy(client: client)
        XCTAssertEqual(stream.presenceLabel(sides: [.left]), "IN BED")
        XCTAssertEqual(stream.presenceLabel(sides: [.right]), "EMPTY")
        let receipt = stream.occupancyUpdatedAt
        await client.setFailure(true)
        await stream.refreshOccupancy(client: client)
        XCTAssertEqual(stream.occupancyUpdatedAt, receipt)
        XCTAssertEqual(stream.presenceLabel(sides: [.right]), "PRESENCE UNKNOWN")
        XCTAssertNil(stream.reportedPresence(side: .left, now: .now.addingTimeInterval(20)))
    }
    func testFlowUsesFirmwareScaleAndChartsBreakAtMissingSamples() throws {
        let instant = SensorObservation.date("2026-10-25T10:00:00Z")
        XCTAssertEqual(instant, SensorObservation.date("2026-10-25T10:00:00.000Z"))
        XCTAssertEqual(instant, SensorObservation.date("2026-10-25T03:00:00-07:00"))
        XCTAssertNil(SensorObservation.date("not a timestamp"))
        let row = try JSONDecoder().decode(SensorFlowReading.self, from: Data(#"{"timestamp":"2026-10-25T10:00:00Z","leftFlowrateCd":2412,"rightFlowrateCd":null,"leftPumpRpm":2000,"rightPumpRpm":0}"#.utf8))
        XCTAssertEqual(row.value(side: .left, rpm: false), 24.12)
        XCTAssertEqual(row.value(side: .left, rpm: true), 2000)
        XCTAssertNil(row.value(side: .right, rpm: false))
        XCTAssertEqual(row.value(side: .right, rpm: true), 0)
        let start = Date(timeIntervalSince1970: 1000)
        let values: [(Date, Double?)] = [(start, 1), (start.addingTimeInterval(10), nil), (start.addingTimeInterval(20), 3), (start.addingTimeInterval(1000), 4)]
        let points = SensorTrendPoint.series("Left", values: values)
        XCTAssertEqual(points.map(\.segment), [0, 1, 2])
        XCTAssertEqual(points.map(\.value), [1, 3, 4])
    }
    func testFailedRefreshRetainsLabeledDataAndNewRangeClearsOldReadings() async {
        let client = SensorFixtureClient(), model = SensorDiagnosticsWorkspace(client: SensorFixtureClient())
        await model.refreshHistory(hours: 6)
        XCTAssertFalse(model.history.isEmpty)
        XCTAssertFalse(model.temperaturePoints.isEmpty)
        XCTAssertFalse(model.humidityPoints.isEmpty)
        let failures = SensorDiagnosticsWorkspace(client: client)
        await failures.refreshFlow(hours: 6)
        let receipt = failures.receipts["Flow"]
        await client.setFailure(true)
        await failures.refreshFlow(hours: 6)
        XCTAssertFalse(failures.flow.isEmpty)
        XCTAssertEqual(failures.receipts["Flow"], receipt)
        XCTAssertFalse(failures.fresh("Flow"))
        await failures.refreshFlow(hours: 24)
        XCTAssertTrue(failures.flow.isEmpty)
        XCTAssertTrue(failures.flowPoints.isEmpty)
        XCTAssertTrue(failures.rpmPoints.isEmpty)
        XCTAssertNil(failures.receipts["Flow"])
    }
    func testCancellationDoesNotPublishHistoryReceipt() async {
        let model = SensorDiagnosticsWorkspace(client: SensorFixtureClient())
        let task = Task { await model.refreshHistory(hours: 6) }
        task.cancel(); await task.value
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(model.receipts["History"])
        XCTAssertFalse(model.loading.contains("History"))
    }
}

private actor SensorFixtureClient: SensorDiagnosticsClient {
    var fails = false
    var delayed = false
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: [CheckedContinuation<Void, Never>] = []
    func delayOccupancy() { delayed = true }
    func waitForOccupancy() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func releaseOccupancy() { continuation?.resume(); continuation = nil }
    func setFailure(_ value: Bool) { fails = value }
    func check() throws { if fails { throw APIError.serverError(message: "Fixture disconnected") } }
    func occupancy() async throws -> SensorOccupancy {
        try check()
        if delayed {
            await withCheckedContinuation { continuation = $0; waiting.forEach { $0.resume() }; waiting = [] }
        }
        return DemoSensorDiagnosticsClient().occupancy()
    }
    func bed() throws -> SensorBedReading? { try check(); return DemoSensorDiagnosticsClient().bed() }
    func freezer() throws -> SensorFreezerReading? { try check(); return DemoSensorDiagnosticsClient().freezer() }
    func water() throws -> WaterLevelReading? { try check(); return DemoSensorDiagnosticsClient().water() }
    func history(start: Date, end: Date, limit: Int) throws -> [BedTempReading] { try check(); return DemoSensorDiagnosticsClient().history(start: start, end: end, limit: limit) }
    func summary(start: Date, end: Date) throws -> SensorEnvironmentSummary { try check(); return DemoSensorDiagnosticsClient().summary(start: start, end: end) }
    func flow(hours: Int) throws -> [SensorFlowReading] { try check(); return DemoSensorDiagnosticsClient().flow(hours: hours) }
}
