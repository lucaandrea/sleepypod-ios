import Foundation
import XCTest
@testable import Sleepypod

@MainActor
final class BaseParityTests: XCTestCase {
    func testStatusRequiresFreshValidPositionsAndDoesNotAssumeIndependentControl() throws {
        let data = Data(#"{"state":"connected","position":{"left":{"head":30,"feet":15},"right":{"head":30,"feet":15}},"stale":false,"busy":false,"lastUpdate":1792962000000,"moving":false,"movingBySide":{"left":false,"right":null},"independentControl":false,"splitBase":false,"error":null}"#.utf8)
        var status = try JSONDecoder().decode(UnifiedBaseStatus.self, from: data)
        XCTAssertTrue(status.ready)
        XCTAssertEqual(status.independentControl, false)
        status.stale = true; XCTAssertFalse(status.ready)
        status.stale = false; status.position?.right.head = 61; XCTAssertFalse(status.ready)
        status.position = .flat; status.busy = true; XCTAssertFalse(status.ready)
        status.busy = false; status.position = nil; XCTAssertFalse(status.ready)
    }

    func testPreviewAndPresetDoNotWriteUntilMoveAndWholeBedIsEnforced() async {
        let client = BaseRecordingClient()
        let model = BaseWorkspace(api: client)
        await model.refresh()
        await model.selectPreset(.read, scope: .left, linked: false, immediately: false)
        XCTAssertEqual(model.targets.left, BasePreset.read.angles)
        XCTAssertEqual(model.targets.right, BasePreset.read.angles)
        XCTAssertEqual(model.measured?.left, BasePreset.relax.angles)
        var moves = await client.moves
        XCTAssertTrue(moves.isEmpty)
        model.speed = 75
        await model.move(.left)
        moves = await client.moves
        XCTAssertEqual(moves, [BaseMoveRequest(angles: BasePreset.read.angles, speed: 75, scope: .both)])
        XCTAssertEqual(model.measured?.left, BasePreset.read.angles)
        XCTAssertFalse(model.previewRequested)
    }

    func testIndependentSidesAndLinkedDraftsFollowCapabilities() async {
        let client = BaseRecordingClient()
        await client.setIndependent(true)
        let model = BaseWorkspace(api: client)
        await model.refresh()
        model.edit(BasePreset.read.angles, scope: .right)
        XCTAssertEqual(model.targets.left, .flat)
        await model.move(.right)
        let moves = await client.moves
        XCTAssertEqual(moves.first?.sides, ["right"])
        XCTAssertEqual(model.measured?.left, BasePreset.relax.angles)
        model.edit(BasePreset.sleep.angles, scope: .left, linked: true)
        XCTAssertEqual(model.targets.left, model.targets.right)
        model.matchDrafts()
        let count = await client.moves.count
        XCTAssertEqual(count, 1, "Linking and editing are drafts, not actuation")
    }

    func testStaleAndBusyDataBlockMovementButNotStop() async {
        var clock = Date(timeIntervalSince1970: 100)
        let client = BaseRecordingClient()
        let model = BaseWorkspace(api: client, now: { clock })
        await model.refresh()
        XCTAssertTrue(model.canMove(.both))
        clock = clock.addingTimeInterval(11)
        XCTAssertFalse(model.canMove(.both))
        await model.move(.both)
        await model.stop()
        let moves = await client.moves
        let stops = await client.stops
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(stops, 1)
        await client.setBusy(true)
        await model.refresh()
        XCTAssertFalse(model.canMove(.both))
        await model.stop()
        let moreStops = await client.stops
        XCTAssertEqual(moreStops, 2)
    }

    func testStopBypassesInFlightMoveAndLateMoveResponseCannotReplaceStopResult() async {
        let client = BaseRecordingClient()
        await client.holdMove()
        let model = BaseWorkspace(api: client)
        await model.refresh()
        let movement = Task { await model.move(.both) }
        await client.waitForMove()
        XCTAssertTrue(model.sending)
        await model.stop()
        XCTAssertTrue(model.notice?.hasPrefix("Stop acknowledged") == true)
        let stops = await client.stops
        XCTAssertEqual(stops, 1)
        await client.releaseMove()
        await movement.value
        XCTAssertTrue(model.notice?.hasPrefix("Stop acknowledged") == true)
    }

    func testImmediatePresetIsExplicitAndFailuresSurvivePolling() async {
        let client = BaseRecordingClient()
        let model = BaseWorkspace(api: client)
        await model.refresh()
        await client.failCommands(true)
        await model.selectPreset(.read, scope: .both, linked: false, immediately: true)
        XCTAssertNotNil(model.commandError)
        XCTAssertTrue(model.previewRequested)
        await model.refresh()
        XCTAssertNotNil(model.commandError)
        XCTAssertEqual(model.measured?.left, BasePreset.relax.angles)
    }

    func testScheduleOverlapUsesExpandedDaysAndSidesIncludingPausedRows() {
        let existing = BaseSchedule(id: 7, dayOfWeek: .weekdays, side: .left, time: "22:00", enabled: false)
        var candidate = BaseSchedule(dayOfWeek: .monday, side: .both)
        XCTAssertTrue(candidate.conflicts(with: existing))
        candidate.dayOfWeek = .saturday; XCTAssertFalse(candidate.conflicts(with: existing))
        candidate.dayOfWeek = .monday; candidate.side = .right; XCTAssertFalse(candidate.conflicts(with: existing))
        candidate.side = .left; candidate.id = 7; XCTAssertFalse(candidate.conflicts(with: existing))
        candidate.id = 8; candidate.time = "22:01"; XCTAssertFalse(candidate.conflicts(with: existing))
        XCTAssertEqual(BaseScheduleDays.sunday.numbers, [0])
        XCTAssertEqual(BaseScheduleDays.saturday.numbers, [6])
        XCTAssertEqual(BaseScheduleDays.weekends.numbers, [0, 6])
        for time in ["25:00", "22:99", "2:00", "ab:cd", "22:00:00"] { candidate.time = time; XCTAssertFalse(candidate.valid) }
    }

    func testScheduleSaveToggleDeletePreserveFieldsAndFailedWritesStayVisible() async {
        let client = BaseRecordingClient()
        let model = BaseWorkspace(api: client)
        await model.refresh(); await model.loadSchedules()
        var custom = BaseSchedule(dayOfWeek: .weekends, presetName: "Reading", time: "20:35", head: 42, feet: 7, feedRate: 75)
        var saved = await model.save(custom)
        XCTAssertTrue(saved)
        custom = model.schedules[0]; custom.enabled = false
        saved = await model.save(custom)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.schedules[0], custom)
        await client.failCommands(true)
        await model.remove(custom)
        XCTAssertEqual(model.schedules.count, 1)
        XCTAssertNotNil(model.scheduleError)
        await client.failCommands(false)
        await model.remove(custom)
        XCTAssertTrue(model.schedules.isEmpty)
    }

    func testCoreRESTMovementAndScheduleContracts() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BaseRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = CoreBaseClient(client: CoreRESTClient(endpoint: URL(string: "https://base.test")!, session: session))
        try await api.move(BaseMoveRequest(angles: BasePreset.read.angles, speed: 75, scope: .both))
        let schedule = BaseSchedule(id: 9, dayOfWeek: .weekends, presetName: "Reading", time: "20:35", enabled: false, head: 42, feet: 7, feedRate: 75)
        let saved = try await api.save(schedule)
        XCTAssertEqual(saved, schedule)
        try await api.stop()
        try await api.reconnect()
        try await api.delete(9)
    }
}

private actor BaseRecordingClient: BaseClient {
    var moves: [BaseMoveRequest] = []
    var stops = 0
    private var current = UnifiedBaseStatus(state: "connected", position: BasePositions(left: BasePreset.relax.angles, right: BasePreset.relax.angles), stale: false, busy: false)
    private var rows: [BaseSchedule] = []
    private var fail = false
    private var hold = false
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func setIndependent(_ value: Bool) { current.independentControl = value }
    func setBusy(_ value: Bool) { current.busy = value }
    func failCommands(_ value: Bool) { fail = value }
    func holdMove() { hold = true }
    func waitForMove() async { if moves.isEmpty { await withCheckedContinuation { started = $0 } } }
    func releaseMove() { release?.resume(); release = nil }
    func status() -> UnifiedBaseStatus { current }
    func move(_ request: BaseMoveRequest) async throws {
        if fail { throw URLError(.timedOut) }
        moves.append(request)
        started?.resume(); started = nil
        if hold { await withCheckedContinuation { release = $0 } }
        for side in request.sides { current.position?[BaseScope(rawValue: side)!] = BaseAngles(head: Double(request.head), feet: Double(request.feet)) }
    }
    func stop() throws { if fail { throw URLError(.timedOut) }; stops += 1 }
    func reconnect() {}
    func schedules() -> [BaseSchedule] { rows }
    func save(_ schedule: BaseSchedule) throws -> BaseSchedule {
        if fail { throw URLError(.timedOut) }
        var row = schedule
        row.id = row.id ?? 1
        rows.removeAll { $0.id == row.id }; rows.append(row)
        return row
    }
    func delete(_ id: Int) throws {
        if fail { throw URLError(.timedOut) }
        rows.removeAll { $0.id == id }
    }
}

private final class BaseRequestProtocol: URLProtocol, @unchecked Sendable {
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
        let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        var valid = false
        var response = Data(#"{"success":true}"#.utf8)
        switch request.url?.path {
        case "/api/base/position":
            valid = request.httpMethod == "POST" && input?.count == 4 && input?["head"] as? Int == 40 && input?["feet"] as? Int == 0
                && input?["feedRate"] as? Int == 75 && input?["sides"] as? [String] == ["left", "right"]
        case "/api/base/schedules":
            valid = request.httpMethod == "POST" && input?.count == 9 && input?["id"] as? Int == 9
                && input?["dayOfWeek"] as? String == "weekends" && input?["side"] as? String == "both"
                && input?["presetName"] as? String == "Reading" && input?["time"] as? String == "20:35"
                && input?["enabled"] as? Bool == false && input?["head"] as? Int == 42 && input?["feet"] as? Int == 7 && input?["feedRate"] as? Int == 75
            response = body
        case "/api/base/stop", "/api/base/reconnect": valid = request.httpMethod == "POST" && input?.isEmpty == true
        case "/api/base/schedules/9": valid = request.httpMethod == "DELETE" && body.isEmpty
        default: break
        }
        guard valid, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
