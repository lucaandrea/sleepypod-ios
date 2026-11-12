import XCTest
@testable import Sleepypod

@MainActor final class OwnerBedRemoteTests: XCTestCase {
    private final class Selection {
        var sides: [Side] = [.left]
        var identity = ["owner-test"]
        var secureStorageAvailable = true
        var factoryAttempts = 0
    }
    private func setup() throws -> (OwnerBedRemoteSource, RemoteOwnerCommandClient, CoreRESTClient, Selection) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        RemoteOwnerURLProtocol.configure(host, value: .init())
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RemoteOwnerURLProtocol.self]
        let transport = CoreRESTClient(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
        let commands = RemoteOwnerCommandClient(), selection = Selection()
        let service = NativeControlService(ledger: .init(directory: nil), client: { commands }, owner: { selection.identity }, live: { true })
        let source = OwnerBedRemoteSource(selected: { selection.sides }, owner: { selection.identity }, permitted: { true }, transport: { transport }, controls: {
            selection.factoryAttempts += 1
            guard selection.secureStorageAvailable else { throw HouseholdFailure.storage }
            return service
        })
        return (source, commands, transport, selection)
    }
    func testInitiallyUnavailableReceiptStoreRecoversWithoutRecreatingRemote() async throws {
        let (source, commands, transport, selection) = try setup(); defer { transport.session.invalidateAndCancel() }
        XCTAssertEqual(selection.factoryAttempts, 0)
        let remote = BedRemoteCoordinator(source: source)
        selection.secureStorageAvailable = false
        let locked = await remote.handle(.init(action: .refresh))
        XCTAssertEqual(locked.outcome, .withheld)
        XCTAssertNil(locked.snapshot)
        selection.secureStorageAvailable = true
        let unlocked = await remote.handle(.init(action: .refresh))
        XCTAssertEqual(unlocked.outcome, .snapshot)
        XCTAssertEqual(unlocked.snapshot?.targetF, 70)
        let again = await remote.handle(.init(action: .refresh))
        XCTAssertEqual(again.outcome, .snapshot)
        XCTAssertEqual(selection.factoryAttempts, 2)
        let sent = await commands.actions; XCTAssertTrue(sent.isEmpty)
    }
    func testFreshReadingSeparatesRequestedTargetAndMeasuredWaterAndDoesNotInventAlarm() async throws {
        let (source, commands, transport, _) = try setup(); defer { transport.session.invalidateAndCancel() }
        let reading = try await source.read()
        XCTAssertEqual(reading.snapshot.targetF, 70)
        XCTAssertEqual(reading.snapshot.zones.first?.measuredF, 71.5)
        XCTAssertTrue(reading.snapshot.canAdjust)
        XCTAssertTrue(reading.snapshot.nextAlarm.contains("unavailable"))
        let sent = await commands.actions; XCTAssertTrue(sent.isEmpty)
    }
    func testTemperatureUsesReceiptRouteAndThirtyMinuteHold() async throws {
        let (source, commands, transport, _) = try setup(); defer { transport.session.invalidateAndCancel() }
        let reading = try await source.read()
        _ = try await source.perform(.init(action: .temperature, lease: reading.snapshot.lease, temperatureF: 69), reviewed: reading, validateBeforeSubmit: {})
        let sent = await commands.actions
        XCTAssertEqual(sent, [.init(kind: "temperature", side: .left, temperature: 69, holdMinutes: 30)])
    }
    func testChangedTargetOrConfigurationRejectsOldGesture() async throws {
        for mode in ["target", "settings"] {
            let (source, commands, transport, _) = try setup(); defer { transport.session.invalidateAndCancel() }
            let reading = try await source.read()
            RemoteOwnerURLProtocol.configure(transport.endpoint.host!, value: .init(mode: mode))
            do { _ = try await source.perform(.init(action: .temperature, lease: reading.snapshot.lease, temperatureF: 69), reviewed: reading, validateBeforeSubmit: {}); XCTFail("Changed bed cannot receive an old gesture") } catch {}
            let sent = await commands.actions; XCTAssertTrue(sent.isEmpty)
        }
    }
    func testAccountOrSelectedSideChangeRejectsBeforeAnyWrite() async throws {
        for changeSide in [true, false] {
            let (source, commands, transport, selection) = try setup(); defer { transport.session.invalidateAndCancel() }
            let reading = try await source.read()
            if changeSide { selection.sides = [.right] } else { selection.identity = ["other-owner"] }
            do { _ = try await source.perform(.init(action: .stopTemperature, lease: reading.snapshot.lease), reviewed: reading, validateBeforeSubmit: {}); XCTFail("Scope changed") } catch {}
            let sent = await commands.actions; XCTAssertTrue(sent.isEmpty)
        }
    }
    func testLowWaterPrimingAndStaleObservationsWithholdTemperatureWithoutBlockingStop() async throws {
        for mode in ["low-water", "priming", "stale"] {
            let (source, commands, transport, _) = try setup(); defer { transport.session.invalidateAndCancel() }
            let reading = try await source.read()
            RemoteOwnerURLProtocol.configure(transport.endpoint.host!, value: .init(mode: mode))
            do { _ = try await source.perform(.init(action: .temperature, lease: reading.snapshot.lease, temperatureF: 69), reviewed: reading, validateBeforeSubmit: {}); XCTFail("Unsafe observations") } catch {}
            _ = try await source.perform(.init(action: .stopTemperature, lease: reading.snapshot.lease), reviewed: reading, validateBeforeSubmit: {})
            let sent = await commands.actions; XCTAssertEqual(sent, [.init(kind: "power", side: .left, powered: false)])
        }
    }
    func testSecondSideFailureIsReportedAsPartialAndNeverRetried() async throws {
        let (source, commands, transport, selection) = try setup(); defer { transport.session.invalidateAndCancel() }
        selection.sides = [.left, .right]; await commands.failRight()
        let reading = try await source.read()
        do { _ = try await source.perform(.init(action: .stopVibration, lease: reading.snapshot.lease), reviewed: reading, validateBeforeSubmit: {}); XCTFail("Do not claim both sides acknowledged") }
        catch { XCTAssertTrue(error.localizedDescription.contains("1 of 2")) }
        let sent = await commands.actions
        XCTAssertEqual(sent, [.init(kind: "vibration.clear", side: .left), .init(kind: "vibration.clear", side: .right)])
    }
    func testFinalRemoteExpiryCheckRunsAfterReceiptCapabilityPreflight() async throws {
        let (source, commands, transport, _) = try setup(); defer { transport.session.invalidateAndCancel() }
        let reading = try await source.read()
        do { _ = try await source.perform(.init(action: .temperature, lease: reading.snapshot.lease, temperatureF: 69), reviewed: reading, validateBeforeSubmit: { throw BedRemoteFailure.expired }); XCTFail("Expired intent") } catch {}
        let sent = await commands.actions; XCTAssertTrue(sent.isEmpty)
    }
}

private actor RemoteOwnerCommandClient: NativeControlClient {
    var actions: [NativeControlAction] = []
    var rejectRight = false
    func failRight() { rejectRight = true }
    func available() {}
    func submit(_ request: NativeControlRequest) throws -> NativeControlReceipt {
        actions.append(request.action)
        if rejectRight, request.action.side == .right { throw URLError(.networkConnectionLost) }
        return .init(version: 1, requestId: request.requestId, action: request.action, issuedAt: request.issuedAt,
            expiresAt: request.expiresAt, receivedAt: request.issuedAt, finishedAt: request.issuedAt + 1,
            lastDispatchAt: request.issuedAt, state: "acknowledged", reason: nil, dispatchCount: 1, physicalVerification: "unverified", replayAllowed: false)
    }
    func read(_ request: NativeControlRequest) throws -> NativeControlReceipt { throw URLError(.networkConnectionLost) }
}

private final class RemoteOwnerURLProtocol: URLProtocol, @unchecked Sendable {
    struct State { var mode = "normal" }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    static func configure(_ host: String, value: State) { lock.withLock { states[host] = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, mode = Self.lock.withLock { Self.states[url.host!]?.mode ?? "normal" }
        do {
            let data: Data; var status = 200
            switch url.path {
            case "/api/settings":
                var settings = SleeperPreferencesSnapshot.demo
                if mode == "settings" { settings.sides.left.name = "Changed person" }
                data = try JSONEncoder().encode(settings)
            case "/api/device/status":
                data = try JSONSerialization.data(withJSONObject: [
                    "leftSide": ["currentTemperature": 71.5, "targetTemperature": 69, "heatingDuration": 1800],
                    "rightSide": ["currentTemperature": 71.5, "targetTemperature": 69, "heatingDuration": 1800],
                    "waterLevel": mode == "low-water" ? "low" : "ok", "isPriming": mode == "priming",
                    "temperatureControl": ["left": ["targetTemperature": mode == "target" ? 75 : 70], "right": ["targetTemperature": 70]]])
            case "/api/v1/capabilities":
                let date = Date().addingTimeInterval(mode == "stale" ? -60 : -1)
                data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "observations": ["device": [
                    "freshness": mode == "stale" ? "stale" : "fresh", "observedAt": date.ISO8601Format(), "expiresAt": date.addingTimeInterval(15).ISO8601Format()]]])
            default: status = 404; data = Data("{}".utf8)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
