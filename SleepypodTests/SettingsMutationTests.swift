import XCTest
@testable import Sleepypod

@MainActor final class SettingsMutationTests: XCTestCase {
    func testReportedUnitOverridesOfflineFallbackAndUnknownWriteRequiresReload() async throws {
        let restore = preserveDisplayDefaults(); defer { restore() }
        let fixture = SettingsHTTPFixture(), (client, session) = fixture.client()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let manager = SettingsManager(api: client)
        UserDefaults.standard.set("celsius", forKey: "temperatureFormat")
        await manager.fetchSettings(); XCTAssertEqual(manager.temperatureFormat, .fahrenheit)
        fixture.state.change { $0.loseWriteReply = true }
        await manager.updateTemperatureFormat(.celsius)
        XCTAssertEqual(manager.temperatureFormat, .fahrenheit); XCTAssertTrue(manager.mustReloadSettings)
        XCTAssertTrue(manager.error?.contains("not confirmed") == true)
        await manager.updateTemperatureFormat(.celsius)
        XCTAssertEqual(fixture.state.inspect { $0.patches.count }, 1, "Unknown writes cannot be repeated")
        await manager.fetchSettings()
        XCTAssertEqual(manager.temperatureFormat, .celsius); XCTAssertFalse(manager.mustReloadSettings); XCTAssertNil(manager.error)
    }
    func testUnitAndAwayPatchesPreserveUnrelatedRemoteChanges() async throws {
        let fixture = SettingsHTTPFixture(), (client, session) = fixture.client()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let original = try await client.getSettings()
        fixture.state.change { $0.device["rebootTime"] = "05:45"; $0.left["name"] = "Taylor"; $0.right["awayMode"] = true }
        var desired = original; desired.temperatureFormat = .celsius
        let saved = try await client.updateSettings(desired, original: original)
        XCTAssertEqual(saved.temperatureFormat, .celsius); XCTAssertEqual(saved.rebootTime, "05:45"); XCTAssertEqual(saved.left.name, "Taylor"); XCTAssertTrue(saved.right.awayMode)
        let unitPatch = fixture.state.inspect { $0.patches[0] }
        XCTAssertEqual(unitPatch.0, "/api/settings/device"); XCTAssertEqual(Set(unitPatch.1.keys), ["temperatureUnit"]); XCTAssertEqual(unitPatch.1["temperatureUnit"] as? String, "C")
        var away = saved; away.right.awayMode = false
        _ = try await client.updateSettings(away, original: saved)
        let awayPatch = fixture.state.inspect { $0.patches[1] }
        XCTAssertEqual(awayPatch.0, "/api/settings/side"); XCTAssertEqual(Set(awayPatch.1.keys), ["side", "awayMode"])
        XCTAssertEqual(awayPatch.1["side"] as? String, "right"); XCTAssertEqual(awayPatch.1["awayMode"] as? Bool, false)
        XCTAssertEqual(fixture.state.inspect { $0.reads }, 5)
    }
    func testConcurrentEditedFieldAndMissingOriginalNeverWrite() async throws {
        let fixture = SettingsHTTPFixture(), (client, session) = fixture.client()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let original = try await client.getSettings()
        fixture.state.change { $0.device["temperatureUnit"] = "C" }
        var desired = original; desired.temperatureFormat = .celsius
        do { _ = try await client.updateSettings(desired, original: original); XCTFail("Expected conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed on the Pod")) }
        do { _ = try await client.updateSettings(desired); XCTFail("Expected original snapshot requirement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("original snapshot")) }
        XCTAssertTrue(fixture.state.inspect { $0.patches.isEmpty })
    }
    func testConnectionKeyChangeDuringPreflightCancelsUnsentSettingsPatch() async throws {
        let originalRevision = UserDefaults.standard.object(forKey: "ownerConnectionRevision")
        defer { UserDefaults.standard.set(originalRevision, forKey: "ownerConnectionRevision") }
        let fixture = SettingsHTTPFixture(), (client, session) = fixture.client()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let original = try await client.getSettings()
        var desired = original; desired.temperatureFormat = .celsius
        fixture.state.change { $0.changeOwnerOnRead = true }
        do { _ = try await client.updateSettings(desired, original: original); XCTFail("The old scope must not write") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.state.inspect { $0.patches.isEmpty })
    }
    func testAcknowledgmentIsRetainedWhenReadbackFails() async throws {
        let restore = preserveDisplayDefaults(); defer { restore() }
        let fixture = SettingsHTTPFixture(), (client, session) = fixture.client()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let manager = SettingsManager(api: client); await manager.fetchSettings()
        fixture.state.change { $0.failReadAfterPatch = true }
        await manager.toggleAwayMode(.left)
        XCTAssertEqual(manager.settings?.left.awayMode, false); XCTAssertTrue(manager.mustReloadSettings)
        XCTAssertTrue(manager.error?.contains("acknowledged") == true)
        await manager.toggleAwayMode(.left)
        XCTAssertEqual(fixture.state.inspect { $0.patches.count }, 1)
    }
    func testAcknowledgedWriteWithDifferentReadbackDoesNotClaimSuccess() async throws {
        let restore = preserveDisplayDefaults(); defer { restore() }
        let fixture = SettingsHTTPFixture(), (client, session) = fixture.client()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let manager = SettingsManager(api: client); await manager.fetchSettings()
        fixture.state.change { $0.ignoreUnitWrite = true }
        await manager.updateTemperatureFormat(.celsius)
        XCTAssertEqual(manager.temperatureFormat, .fahrenheit)
        XCTAssertTrue(manager.mustReloadSettings)
        XCTAssertTrue(manager.error?.contains("do not reflect") == true)
        await manager.updateTemperatureFormat(.celsius)
        XCTAssertEqual(fixture.state.inspect { $0.patches.count }, 1)
    }
}

private final class SettingsHTTPFixture {
    let host = "settings-\(UUID().uuidString.lowercased()).invalid"
    let state = SettingsHTTPState()
    func client() -> (SleepypodCoreClient, URLSession) {
        SettingsHTTPProtocol.registry.register(state, host: host)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SettingsHTTPProtocol.self]
        let session = URLSession(configuration: config)
        return (SleepypodCoreClient(session: session, baseURL: URL(string: "https://\(host)")!), session)
    }
    func remove() { SettingsHTTPProtocol.registry.remove(host) }
}
private final class SettingsHTTPState: @unchecked Sendable {
    struct Value {
        var device: [String: Any] = ["timezone": "America/Los_Angeles", "temperatureUnit": "F", "timeFormat": "12h", "rebootDaily": false, "rebootTime": "04:00", "primePodDaily": false, "primePodTime": "05:00", "defaultScheduleEndAction": "turn_off"]
        var left: [String: Any] = ["side": "left", "name": "Alex", "awayMode": false]
        var right: [String: Any] = ["side": "right", "name": "Sam", "awayMode": false]
        var reads = 0
        var patches: [(String, [String: Any])] = []
        var loseWriteReply = false
        var failReadAfterPatch = false
        var ignoreUnitWrite = false
        var changeOwnerOnRead = false
    }
    private var value = Value()
    private let lock = NSLock()
    func inspect<Result>(_ body: (Value) -> Result) -> Result { lock.withLock { body(value) } }
    func change(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
    func reply(_ request: URLRequest) throws -> Data {
        let input = try request.httpMethod == "PATCH" ? Self.body(request) : [:]
        return try lock.withLock {
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/trpc/settings.getAll"):
                value.reads += 1
                if value.changeOwnerOnRead { UserDefaults.standard.set(UUID().uuidString, forKey: "ownerConnectionRevision") }
                if value.failReadAfterPatch && !value.patches.isEmpty { throw URLError(.notConnectedToInternet) }
                return try JSONSerialization.data(withJSONObject: ["result": ["data": ["json": ["device": value.device, "sides": ["left": value.left, "right": value.right], "gestures": ["left": [], "right": []]]]]])
            case ("PATCH", "/api/settings/device"):
                value.patches.append((request.url!.path, input))
                value.device.merge(input.filter { !value.ignoreUnitWrite || $0.key != "temperatureUnit" }) { _, new in new }
            case ("PATCH", "/api/settings/side"):
                value.patches.append((request.url!.path, input))
                if input["side"] as? String == "left" { value.left.merge(input) { _, new in new } } else { value.right.merge(input) { _, new in new } }
            default: XCTFail("Unexpected settings route"); throw URLError(.unsupportedURL)
            }
            if value.loseWriteReply { throw URLError(.timedOut) }
            return Data("{}".utf8)
        }
    }
    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
private final class SettingsHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: SettingsHTTPState] = [:]
    func register(_ state: SettingsHTTPState, host: String) { lock.withLock { states[host] = state } }
    func remove(_ host: String) { _ = lock.withLock { states.removeValue(forKey: host) } }
    func state(_ host: String) -> SettingsHTTPState? { lock.withLock { states[host] } }
}
private final class SettingsHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = SettingsHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host.flatMap(registry.state) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let state = Self.registry.state(url.host ?? "") else { return }
        do {
            let body = try state.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func preserveDisplayDefaults() -> () -> Void {
    let defaults = UserDefaults.standard
    let temperature = defaults.object(forKey: "temperatureFormat"), clock = defaults.object(forKey: "podTimeFormat")
    return { defaults.set(temperature, forKey: "temperatureFormat"); defaults.set(clock, forKey: "podTimeFormat") }
}
