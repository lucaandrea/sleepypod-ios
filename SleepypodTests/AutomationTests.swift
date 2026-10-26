import XCTest
@testable import Sleepypod

@MainActor final class AutomationTests: XCTestCase {
    func testNestedRuleRoundTripsWithoutLosingBooleanOrExpressionStructure() throws {
        let condition = AutomationCondition.all([
            .any([.days([.friday, .saturday]), .time(start: "23:00", end: "06:00")]),
            .not(.compare(operation: "==", left: .signal("water.low"), right: .literal(1))),
            .between(subject: .window(function: "avg", signal: "right.movement", minutes: 15), minimum: .literal(5), maximum: .literal(50))
        ])
        let action = AutomationAction(kind: .setTemperature, side: .right,
            temp: .clamp(value: .binary(operation: "-", left: .signal("right.targetTemperature"), right: .literal(2)), minimum: .literal(65), maximum: .literal(85)),
            clamp: .init(min: 65, max: 85), durationSec: 1800, mode: "one-shot", holdMinutes: 30)
        let value = AutomationDefinition(side: nil, conditions: condition, actions: [action])
        XCTAssertNil(value.validation)
        XCTAssertEqual(try JSONDecoder().decode(AutomationDefinition.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(condition.signals, ["water.low", "right.movement"])
    }
    func testPatchExplicitlyClearsSideAndCooldownAndHasNoOutputFields() throws {
        let body = try json(AutomationPatch(id: 9, definition: .init(side: nil, cooldownMin: nil)))
        XCTAssertTrue(body["side"] is NSNull); XCTAssertTrue(body["cooldownMin"] is NSNull)
        XCTAssertEqual(body["id"] as? Int, 9)
        XCTAssertNil(body["createdAt"]); XCTAssertNil(body["definition"])
    }
    func testKindChangesCannotSendExtraneousFieldsToStrictCoreUnions() throws {
        let trigger = AutomationTrigger(kind: .timeOfDay, everyMin: 12, signal: "right.movement", at: "22:30", days: [.monday])
        XCTAssertEqual(Set(try json(trigger).keys), ["kind", "at", "days"])
        let action = AutomationAction(kind: .setPower, message: "stale", side: .right, temp: .literal(72), clamp: .init(min: 65, max: 85), durationSec: 15, on: true, mode: "policy")
        XCTAssertEqual(Set(try json(action).keys), ["kind", "side", "temp", "on", "mode"])
        let notify = AutomationAction(kind: .notify, message: "hello", side: .left, temp: .literal(70), on: true)
        XCTAssertEqual(Set(try json(notify).keys), ["kind", "message"])
    }
    func testValidationRejectsInvalidClocksFractionalLimitsAndUnboundedTrees() {
        XCTAssertFalse(AutomationCondition.validClock("1:000")); XCTAssertFalse(AutomationCondition.validClock("24:00"))
        XCTAssertTrue(AutomationCondition.validClock("23:59"))
        XCTAssertFalse(AutomationAction(kind: .setTemperature, temp: .literal(72), clamp: .init(min: 65.5, max: 85)).valid)
        var condition = AutomationCondition.all([])
        for _ in 0..<17 { condition = .not(condition) }
        XCTAssertNotNil(AutomationDefinition(conditions: condition).validation)
        XCTAssertNotNil(AutomationDefinition(conditions: .all(Array(repeating: .all(Array(repeating: .days([.monday]), count: 24)), count: 24))).validation)
        XCTAssertFalse(AutomationExpression.binary(operation: "/", left: .literal(72), right: .literal(0)).valid())
    }
    func testActivityNightBoundariesFollowPodTimezoneAcrossDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(AutomationDates.parse("2026-11-02T05:00:00Z"))
        let starts = AutomationActivity.nightStarts(count: 3, timeZone: zone, now: now)
        XCTAssertEqual(starts.count, 3)
        XCTAssertEqual(starts[2] - starts[1], 25 * 3600 * 1000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        for start in starts { XCTAssertEqual(calendar.component(.hour, from: Date(timeIntervalSince1970: start / 1000)), 18) }
    }
    func testActionReviewIncludesOptionalPowerTemperatureSideAndExactRevert() {
        let power = AutomationAction(kind: .setPower, side: .right, temp: .literal(76), on: true, mode: "one-shot", holdMinutes: 30)
        XCTAssertTrue(power.summary.contains("76°F")); XCTAssertTrue(power.summary.contains("right")); XCTAssertTrue(power.summary.contains("hold 30 min"))
        let temperature = AutomationAction(kind: .setTemperature, temp: .literal(72), durationSec: 5)
        XCTAssertTrue(temperature.summary.contains("revert after 5 sec"))
    }
    func testUnknownRuleLanguageIsRejectedInsteadOfFlattened() {
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationCondition.self, from: Data(#"{"kind":"futureCondition","value":1}"#.utf8)))
    }
    func testMissingTraceValuesBreakTheLineInsteadOfBecomingZero() {
        let points = AutomationTracePoint.points([72, nil, 74, .nan, 76, 77])
        XCTAssertEqual(points.map(\.id), [0, 2, 4, 5])
        XCTAssertEqual(points.map(\.segment), [0, 1, 2, 2]); XCTAssertEqual(points.map(\.value), [72, 74, 76, 77])
    }
    func testBacktestRequestContainsOnlySupportedInlineRuleFields() throws {
        let body = try json(AutomationBacktestRequest(side: .right, sleepRecordId: 19, rule: .init(definition: .init(side: nil))))
        XCTAssertEqual(body["side"] as? String, "right"); XCTAssertEqual(body["sleepRecordId"] as? Int, 19)
        let rule = try XCTUnwrap(body["rule"] as? [String: Any])
        XCTAssertEqual(Set(rule.keys), ["side", "cooldownMin", "trigger", "conditions", "actions"])
        XCTAssertTrue(rule["side"] is NSNull)
    }
    func testCoreRoutesAndAtomicModePayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AutomationProtocol.self]
        let client = CoreAutomationClient(transport: .init(endpoint: URL(string: "https://automation.invalid")!, session: .init(configuration: configuration)))
        let listed = try await client.rules(); XCTAssertEqual(listed.first?.id, 9)
        let enabled = try await client.globalEnabled(); XCTAssertFalse(enabled)
        let enabledNow = try await client.setGlobalEnabled(true); XCTAssertTrue(enabledNow)
        let active = try await client.mode(id: 9, mode: .active); XCTAssertEqual(active.definition.mode, .active)
        let changed = try await client.update(id: 9, definition: .init(side: nil)); XCTAssertNil(changed.definition.side)
        let created = try await client.create(.init(side: nil)); XCTAssertEqual(created.id, 9)
        let nights = try await client.nights(side: .right); XCTAssertEqual(nights.first?.id, 19)
        let backtest = try await client.backtest(.init(side: nil), side: .right, night: 19); XCTAssertFalse(backtest.ok)
        try await client.delete(id: 9)
    }
    func testDiagnosticsAndHistoryRoutesPreserveMissingValuesAndCommandProvenance() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AutomationProtocol.self]
        let client = CoreAutomationClient(transport: .init(endpoint: URL(string: "https://automation.invalid")!, session: .init(configuration: configuration)))
        let diagnostics = try await client.diagnostics()
        XCTAssertEqual(diagnostics.rules.first?.runs.first?.label, "Missing signal")
        XCTAssertFalse(diagnostics.rules.first?.runs.first?.sent ?? true)
        XCTAssertTrue(diagnostics.rules.first?.signals.keys.contains("right.movement") == true)
        XCTAssertNil(diagnostics.rules.first?.signals["right.movement"] ?? nil)
        let tonight = try await client.tonight(); XCTAssertEqual(tonight.sides.left.control?.blocked, "off")
        XCTAssertNil(tonight.sides.right.control)
        let activity = try await client.activity(nightStarts: [1792875600000])
        XCTAssertEqual(activity.nights.first?.entries.first?.code, "signal-unavailable")
        let replay = try await client.zones(side: .right, night: 19)
        XCTAssertEqual(replay.frames.first?.zones, [0.1, 0.6, 0.2])
    }
    func testCoreGeneratedReplayFixtureDecodesGapsClampsAndProvenance() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "automation-backtest-fixture", withExtension: "json"))
        let fixture = try JSONDecoder().decode(AutomationBacktest.self, from: Data(contentsOf: url))
        let result = try XCTUnwrap(fixture.result)
        XCTAssertEqual(result.mode, "policy"); XCTAssertEqual(result.clockMin.count, 181)
        XCTAssertTrue(result.primary?.values.contains(where: { $0 == nil }) == true)
        XCTAssertGreaterThan(result.summary.clampHits, 0)
        XCTAssertTrue(fixture.message?.contains("synthetic") == true)
    }
    func testChangingNightDuringReplayDiscardsOldResponseAndUnlocksRun() async {
        let model = AutomationBacktestWorkspace(side: .left, client: ControlledAutomationClient())
        await model.load()
        let pending = Task { await model.run(.init()) }
        try? await Task.sleep(for: .milliseconds(10)); model.night = 19
        await pending.value
        XCTAssertFalse(model.running); XCTAssertNil(model.result)
    }
    func testConcurrentRuleChangeKeepsDraftAndDoesNotWrite() async throws {
        let client = ControlledAutomationClient(); let model = AutomationWorkspace(client: client)
        await model.load(); let original = try XCTUnwrap(model.rules.first)
        try await client.changeExternally()
        var draft = original.definition; draft.name = "My draft"
        let saved = await model.save(draft, original: original); XCTAssertFalse(saved)
        XCTAssertTrue(model.error?.contains("changed on another device") == true)
        let writes = await client.writes(); XCTAssertEqual(writes, 0)
    }
    func testFailedReadDisablesWritesWithoutClaimingOffOrErasingRules() async {
        let client = ControlledAutomationClient(); let model = AutomationWorkspace(client: client)
        await model.load(); XCTAssertTrue(model.ready); XCTAssertEqual(model.rules.count, 2)
        await client.failReads(); await model.load()
        XCTAssertFalse(model.ready); XCTAssertEqual(model.rules.count, 2); XCTAssertNotNil(model.error)
        let saved = await model.save(.init(), original: nil); XCTAssertFalse(saved); let writes = await client.writes(); XCTAssertEqual(writes, 0)
    }
    func testSuccessfulCreateAndModeChangeStayInSyncWithReturnedRule() async throws {
        let client = DemoAutomationClient(); let model = AutomationWorkspace(client: client)
        await model.load()
        let saved = await model.save(.init(name: "Native draft"), original: nil); XCTAssertTrue(saved)
        let created = try XCTUnwrap(model.rules.first { $0.definition.name == "Native draft" })
        XCTAssertEqual(created.definition.mode, .dryRun)
        await model.setMode(.off, for: created)
        XCTAssertEqual(model.rules.first { $0.id == created.id }?.definition.mode, .off)
    }
    func testBacktestResponseRemainsMarkedStaleAfterNightOrDraftChanges() async {
        let model = AutomationBacktestWorkspace(side: .left, client: DemoAutomationClient())
        let draft = AutomationDefinition()
        await model.load(); await model.run(draft); XCTAssertTrue(model.isCurrent(draft))
        model.night = 5; XCTAssertFalse(model.isCurrent(draft))
        model.night = nil; var changed = draft; changed.name = "Changed"; XCTAssertFalse(model.isCurrent(changed))
    }
    func testLostCreateRequiresExplicitReadAndRecoversWithoutDuplicate() async throws {
        let client = ControlledAutomationClient(); let model = AutomationWorkspace(client: client)
        await model.load(); await client.loseNext("create")
        let draft = AutomationDefinition(name: "Lost response draft")
        let saved = await model.save(draft, original: nil)
        XCTAssertFalse(saved); XCTAssertTrue(model.requiresReload); XCTAssertFalse(model.ready)
        await model.load(userInitiated: false)
        XCTAssertTrue(model.requiresReload)
        let repeated = await model.save(draft, original: nil); XCTAssertFalse(repeated)
        let count = await client.writes(); XCTAssertEqual(count, 1)
        await model.load()
        XCTAssertTrue(model.ready); XCTAssertFalse(model.requiresReload)
        XCTAssertEqual(model.recoveredCreation?.definition, draft)
        XCTAssertEqual(model.rules.filter { $0.definition == draft }.count, 1)
    }
    func testLostMutationResponsesRequireReadbackForEveryWriteKind() async throws {
        for operation in ["update", "mode", "global", "delete"] {
            let client = ControlledAutomationClient(); let model = AutomationWorkspace(client: client)
            await model.load(); let original = try XCTUnwrap(model.rules.first)
            await client.loseNext(operation)
            switch operation {
            case "update": var changed = original.definition; changed.name = "Saved remotely"; _ = await model.save(changed, original: original)
            case "mode": await model.setMode(.off, for: original)
            case "global": await model.setGlobal(true)
            default: _ = await model.delete(original)
            }
            XCTAssertTrue(model.requiresReload, operation); XCTAssertFalse(model.ready, operation)
            await model.load(userInitiated: false); XCTAssertFalse(model.ready, operation)
            await client.failReads(); await model.load(); XCTAssertTrue(model.requiresReload, operation)
            await client.allowReads(); await model.load(); XCTAssertTrue(model.ready, operation)
            XCTAssertFalse(model.requiresReload, operation)
            let count = await client.writes(); XCTAssertEqual(count, 1, operation)
        }
    }
    func testOwnerChangeDuringPreflightCannotSendMutation() async throws {
        let key = "ownerConnectionRevision", defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let client = ControlledAutomationClient(); let model = AutomationWorkspace(client: client)
        await model.load(); let original = try XCTUnwrap(model.rules.first)
        await client.pauseNextRead()
        let pending = Task { await model.setMode(.active, for: original) }
        for _ in 0..<100 { if await client.isReadPaused() { break }; try await Task.sleep(for: .milliseconds(5)) }
        let paused = await client.isReadPaused(); XCTAssertTrue(paused)
        defaults.set(UUID().uuidString, forKey: key)
        await client.resumeRead(); await pending.value
        let count = await client.writes(); XCTAssertEqual(count, 0)
    }
    func testNavigationInvalidationDuringPreflightCannotSendMutation() async throws {
        let client = ControlledAutomationClient(); let model = AutomationWorkspace(client: client)
        await model.load(); let original = try XCTUnwrap(model.rules.first)
        await client.pauseNextRead()
        let pending = Task { await model.delete(original) }
        for _ in 0..<100 { if await client.isReadPaused() { break }; try await Task.sleep(for: .milliseconds(5)) }
        model.invalidate(); await client.resumeRead()
        let removed = await pending.value; XCTAssertFalse(removed); XCTAssertFalse(model.ready)
        let count = await client.writes(); XCTAssertEqual(count, 0)
    }
    func testAlreadyCancelledCreateAndGlobalActionCannotDispatch() async throws {
        let client = ControlledAutomationClient()
        let workspace = AutomationWorkspace(client: client)
        await workspace.load(); let definition = try XCTUnwrap(workspace.rules.first).definition
        let create = Task { await workspace.save(definition, original: nil) }; create.cancel()
        let saved = await create.value; XCTAssertFalse(saved)
        let global = Task { await workspace.setGlobal(true) }; global.cancel(); await global.value
        let count = await client.writes(); XCTAssertEqual(count, 0)
    }
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]) }
}

private actor ControlledAutomationClient: AutomationClient {
    let demo = DemoAutomationClient()
    var failed = false
    var writeCount = 0
    var lostOperation: String?
    var pauseRead = false
    var pausedRead: CheckedContinuation<Void, Never>?
    func loseNext(_ operation: String) { lostOperation = operation }
    func allowReads() { failed = false }
    func pauseNextRead() { pauseRead = true }
    func isReadPaused() -> Bool { pausedRead != nil }
    func resumeRead() { pausedRead?.resume(); pausedRead = nil }
    private func finish(_ operation: String) throws {
        if lostOperation == operation { lostOperation = nil; throw URLError(.networkConnectionLost) }
    }
    func failReads() { failed = true }
    func writes() -> Int { writeCount }
    func changeExternally() async throws {
        if let rule = await demo.rules().first { var definition = rule.definition; definition.name = "Other device"; _ = try await demo.update(id: rule.id, definition: definition) }
    }
    func rules() async throws -> [AutomationRule] {
        if pauseRead { pauseRead = false; await withCheckedContinuation { pausedRead = $0 } }
        if failed { throw APIError.noBaseURL }; return await demo.rules()
    }
    func summaries() async -> [AutomationReplaySummary] { await demo.summaries() }
    func range(_ definition: AutomationDefinition, nights: Int) async -> AutomationReplaySummary { await demo.range(definition, nights: nights) }
    func globalEnabled() async -> Bool { await demo.globalEnabled() }
    func setGlobalEnabled(_ enabled: Bool) async throws -> Bool { writeCount += 1; let value = await demo.setGlobalEnabled(enabled); try finish("global"); return value }
    func create(_ definition: AutomationDefinition) async throws -> AutomationRule { writeCount += 1; let value = try await demo.create(definition); try finish("create"); return value }
    func update(id: Int, definition: AutomationDefinition) async throws -> AutomationRule { writeCount += 1; let value = try await demo.update(id: id, definition: definition); try finish("update"); return value }
    func mode(id: Int, mode: AutomationMode) async throws -> AutomationRule { writeCount += 1; let value = try await demo.mode(id: id, mode: mode); try finish("mode"); return value }
    func delete(id: Int) async throws { writeCount += 1; await demo.delete(id: id); try finish("delete") }
    func activity(nightStarts: [Double]) async -> AutomationActivity { await demo.activity(nightStarts: nightStarts) }
    func zones(side: Side, night: Int?) async -> AutomationZoneReplay { await demo.zones(side: side, night: night) }
    func diagnostics() async -> AutomationDiagnostics { await demo.diagnostics() }
    func tonight() async -> AutomationTonight { await demo.tonight() }
    func nights(side: Side) async -> [AutomationNight] { await demo.nights(side: side) }
    func backtest(_ definition: AutomationDefinition, side: Side, night: Int?) async -> AutomationBacktest { try? await Task.sleep(for: .milliseconds(80)); return await demo.backtest(definition, side: side, night: night) }
}

private final class AutomationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "automation.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? ""
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 2048); var result = Data()
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(bytes, count: count) }; data = result
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var response = "{}"
        let rule = #"{"id":9,"name":"Test rule","enabled":true,"side":null,"priority":0,"dryRun":true,"cooldownMin":null,"trigger":{"kind":"tick","everyMin":1},"conditions":{"kind":"and","conditions":[]},"actions":[{"kind":"notify","message":"hello"}],"createdAt":"2026-10-25T00:00:00Z","updatedAt":"2026-10-25T00:00:00Z"}"#
        switch (method, url.path) {
        case ("GET", "/api/automations"): response = "[\(rule)]"
        case ("GET", "/api/automations/kill-switch"): response = #"{"enabled":false}"#
        case ("POST", "/api/automations/kill-switch"): XCTAssertEqual(body["enabled"] as? Bool, true); response = #"{"enabled":true}"#
        case ("PATCH", "/api/automations"):
            XCTAssertEqual(body["id"] as? Int, 9)
            if body["name"] == nil { XCTAssertEqual(Set(body.keys), ["id", "enabled", "dryRun"]); XCTAssertEqual(body["enabled"] as? Bool, true); XCTAssertEqual(body["dryRun"] as? Bool, false); response = rule.replacingOccurrences(of: "\"dryRun\":true", with: "\"dryRun\":false") }
            else { XCTAssertTrue(body["side"] is NSNull); response = rule }
        case ("POST", "/api/automations"): XCTAssertNil(body["id"]); XCTAssertTrue(body["side"] is NSNull); response = rule
        case ("DELETE", "/api/automations"): XCTAssertEqual(query, ["id": "9"]); response = #"{"success":true}"#
        case ("GET", "/api/automations/nights"): XCTAssertEqual(query, ["side": "right", "limit": "30"]); response = #"[{"sleepRecordId":19,"label":"Last night","date":"2026-10-24","startMs":1792875600000,"endMs":1792904400000}]"#
        case ("POST", "/api/automations/backtest"):
            XCTAssertEqual(body["side"] as? String, "right"); XCTAssertEqual(body["sleepRecordId"] as? Int, 19)
            response = #"{"ok":false,"message":"No history","night":null,"result":null}"#
        case ("GET", "/api/automations/diagnostics"):
            XCTAssertEqual(query, ["hours": "3"])
            response = "{\"now\":\"2026-10-25T23:00:00Z\",\"since\":\"2026-10-25T20:00:00Z\",\"startOfDay\":\"2026-10-25T07:00:00Z\",\"globalEnabled\":false,\"rules\":[" + rule.dropLast() + ",\"runs\":[{\"t\":\"2026-10-25T22:00:00Z\",\"outcome\":\"skipped\",\"reason\":\"condition-unknown\",\"sent\":false}],\"signals\":{\"right.movement\":null}}]}"
        case ("GET", "/api/automations/tonight"):
            response = #"{"now":1792875600000,"sides":{"left":{"control":{"source":null,"blocked":"off"},"hold":null,"runOnceUntil":null,"lastAutopilot":null},"right":{"control":null,"hold":null,"runOnceUntil":null,"lastAutopilot":null}}}"#
        case ("POST", "/api/automations/activity"):
            XCTAssertEqual(body["nightStarts"] as? [Double], [1792875600000])
            response = #"{"now":1792904400000,"nights":[{"start":1792875600000,"entries":[{"ruleId":9,"ruleName":"Test rule","outcome":"skipped","code":"signal-unavailable","start":1792875600000,"end":1792875720000,"count":2,"temp":null,"sides":["right"]}]}],"holds":[]}"#
        case ("GET", "/api/automations/cap-zone-replay"):
            XCTAssertEqual(query, ["side":"right", "sleepRecordId":"19", "maxFrames":"300"])
            response = #"{"ok":true,"night":{"label":"Last night","date":"2026-10-24"},"frames":[{"tMs":1792875600000,"zones":[0.1,0.6,0.2],"peakZone":1}]}"#
        default: XCTFail("Unexpected automation request: \(method) \(url.path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
