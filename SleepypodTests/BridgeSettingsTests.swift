import XCTest
@testable import Sleepypod

@MainActor final class BridgeSettingsTests: XCTestCase {
    func testBlankReplacementPreservesPasswordAndUnchangedSources() async throws {
        let settings = await DemoMQTTSettingsClient().settings()
        var draft = MQTTSettingsDraft(settings)
        XCTAssertTrue(draft.patch(comparedTo: settings).isEmpty)
        draft.topicPrefix = "bedroom/pod"
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.patch(comparedTo: settings))) as? [String: String]
        XCTAssertEqual(body, ["topicPrefix": "bedroom/pod"])
        draft.password = " fixture replacement "
        XCTAssertEqual(draft.patch(comparedTo: settings).password, " fixture replacement ")
        XCTAssertFalse(draft.safeMessage("Rejected fixture replacement token").contains(" fixture replacement "))
    }
    func testTLSRequiresEncryptedURLAndCredentialsStaySeparate() async {
        var draft = MQTTSettingsDraft(await DemoMQTTSettingsClient().settings())
        XCTAssertNil(draft.brokerIssue)
        draft.tlsEnabled = true
        XCTAssertTrue(draft.brokerIssue?.contains("mqtts://") == true)
        draft.url = "mqtts://broker.example.invalid:8883"
        XCTAssertNil(draft.brokerIssue)
        draft.url = "mqtts://someone:secret@broker.example.invalid"
        XCTAssertTrue(draft.brokerIssue?.contains("credentials") == true)
        draft.url = "https://broker.example.invalid"
        XCTAssertNotNil(draft.brokerIssue)
        draft.topicPrefix = "bedroom/#"
        XCTAssertNotNil(draft.topicIssue)
    }
    func testHomeKitReadFailureHidesPairingAndBlocksMutation() async {
        let client = BridgeFixtureClient()
        let model = HomeKitBridgeWorkspace(client: client)
        await model.refresh()
        XCTAssertTrue(model.canChange)
        XCTAssertFalse(model.fresh(now: .now.addingTimeInterval(16)))
        await client.failReads(); await model.refresh()
        XCTAssertNotNil(model.status)
        XCTAssertFalse(model.canChange)
        XCTAssertFalse(model.fresh())
    }
    func testEarlierHomeKitPollCannotUndoMutation() async {
        let client = BridgeFixtureClient()
        let delayed = HomeKitBridgeWorkspace(client: client)
        await delayed.refresh()
        await client.delayRead()
        let task = Task { await delayed.refresh() }
        await client.waitForRead()
        await delayed.setEnabled(false)
        await client.releaseRead()
        await task.value
        XCTAssertEqual(delayed.status?.enabled, false)
    }
    func testHomeKitFailureNeedsReadbackAndDoesNotRetry() async {
        let client = BridgeFixtureClient(failWrite: true)
        let failed = HomeKitBridgeWorkspace(client: client)
        await failed.refresh(); await failed.setEnabled(false); await failed.setEnabled(false)
        XCTAssertTrue(failed.mustRefresh); XCTAssertNil(failed.receipt)
        let writes = await client.writes
        XCTAssertEqual(writes, 1)
        await failed.refresh()
        XCTAssertTrue(failed.canChange)
        XCTAssertEqual(failed.status?.enabled, true)
    }
    func testHomeKitResetUsesNewPairingStateAndFormatsCode() async {
        let model = HomeKitBridgeWorkspace(client: DemoHomeKitBridgeClient())
        await model.refresh(); await model.resetPairing()
        XCTAssertEqual(model.status?.pairedControllers, [])
        XCTAssertEqual(model.status?.formattedCode, "031-45-154")
        XCTAssertTrue(model.receipt?.contains("Remove the old bridge") == true)
    }
    func testMQTTStatusPollingPreservesDraftAndTestDoesNotSave() async {
        let client = MQTTFixtureClient()
        let tested = MQTTSettingsWorkspace(client: client)
        await tested.loadSettings()
        tested.draft?.topicPrefix = "bedroom/pod"
        await tested.refreshStatus()
        XCTAssertEqual(tested.draft?.topicPrefix, "bedroom/pod")
        await tested.testConnection()
        XCTAssertEqual(tested.currentTestResult?.ok, true)
        let writes = await client.writes
        XCTAssertEqual(writes, 0)
        tested.draft?.url = "mqtt://another.example.invalid"
        XCTAssertNil(tested.currentTestResult)
    }
    func testLeavingMQTTDoesNotRestoreSecretFromLateTest() async {
        let client = MQTTFixtureClient(delayTest: true), model = MQTTSettingsWorkspace(client: client)
        await model.loadSettings(); model.draft?.password = "synthetic-secret"
        let task = Task { await model.testConnection() }
        await client.waitForTest()
        model.clearSecret()
        await client.releaseTest()
        await task.value
        XCTAssertEqual(model.draft?.password, "")
        XCTAssertNil(model.testedInput)
        XCTAssertNil(model.currentTestResult)
    }
    func testMQTTConflictPreventsOverwritingRemoteEdits() async {
        let client = MQTTFixtureClient()
        let edited = MQTTSettingsWorkspace(client: client)
        await edited.loadSettings(); edited.draft?.topicPrefix = "local-edit"
        await client.changeTopic("remote-edit")
        await edited.save()
        let writes = await client.writes
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(edited.mustRefresh)
        XCTAssertTrue(edited.actionError?.contains("changed while") == true)
        XCTAssertEqual(edited.draft?.topicPrefix, "local-edit")
    }
    func testMQTTFailedSaveRequiresReadbackAndKeepsDraft() async {
        let client = MQTTFixtureClient(failWrite: true), model = MQTTSettingsWorkspace(client: client)
        await model.loadSettings(); model.draft?.topicPrefix = "bedroom/pod"
        await model.save(); await model.save()
        let writes = await client.writes
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(model.mustRefresh); XCTAssertNil(model.saveReceipt)
        XCTAssertEqual(model.draft?.topicPrefix, "bedroom/pod")
    }
    func testMQTTAcknowledgedSaveClearsSecretAndRefreshesConfiguration() async {
        let model = MQTTSettingsWorkspace(client: DemoMQTTSettingsClient())
        await model.loadSettings(); model.draft?.topicPrefix = "bedroom/pod"; model.draft?.password = "synthetic-secret"
        await model.save()
        XCTAssertEqual(model.settings?.topicPrefix, "bedroom/pod")
        XCTAssertEqual(model.draft?.password, "")
        XCTAssertNotNil(model.saveReceipt); XCTAssertNil(model.actionError)
        XCTAssertFalse(model.dirty)
        XCTAssertTrue(model.statusFresh())
    }
    func testMQTTReadbackFailureDistinguishesAcknowledgedSave() async {
        let client = MQTTFixtureClient(failReadback: true), model = MQTTSettingsWorkspace(client: client)
        await model.loadSettings(); model.draft?.topicPrefix = "bedroom/pod"
        await model.save()
        XCTAssertNotNil(model.saveReceipt)
        XCTAssertTrue(model.actionError?.contains("Saved, but") == true)
        XCTAssertTrue(model.mustRefresh)
    }
}

private actor BridgeFixtureClient: HomeKitBridgeClient {
    private let demo = DemoHomeKitBridgeClient()
    private let failWrite: Bool
    private var readFails = false
    private var delayed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var writes = 0
    init(failWrite: Bool = false) { self.failWrite = failWrite }
    func failReads() { readFails = true }
    func delayRead() { delayed = true }
    func waitForRead() async { if continuation == nil { await withCheckedContinuation { waiters.append($0) } } }
    func releaseRead() { continuation?.resume(); continuation = nil }
    func status() async throws -> HomeKitBridgeStatus {
        if readFails { throw APIError.noBaseURL }
        let captured = await demo.status()
        if delayed {
            delayed = false
            await withCheckedContinuation { continuation = $0; waiters.forEach { $0.resume() }; waiters = [] }
        }
        return captured
    }
    func setEnabled(_ enabled: Bool) async throws -> HomeKitBridgeStatus {
        writes += 1
        if failWrite { throw APIError.noBaseURL }
        return await demo.setEnabled(enabled)
    }
    func resetPairing() async throws -> HomeKitBridgeStatus { await demo.resetPairing() }
}
private actor MQTTFixtureClient: MQTTSettingsClient {
    private let demo = DemoMQTTSettingsClient()
    private let failWrite: Bool
    private let failReadback: Bool
    private let delayTest: Bool
    private var pendingTest: CheckedContinuation<Void, Never>?
    private var testWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var writes = 0
    init(failWrite: Bool = false, failReadback: Bool = false, delayTest: Bool = false) {
        self.failWrite = failWrite; self.failReadback = failReadback; self.delayTest = delayTest
    }
    func waitForTest() async { if pendingTest == nil { await withCheckedContinuation { testWaiters.append($0) } } }
    func releaseTest() { pendingTest?.resume(); pendingTest = nil }
    func changeTopic(_ topic: String) async { await demo.save(.init(topicPrefix: topic)) }
    func settings() async throws -> MQTTSettings {
        if failReadback && writes > 0 { throw APIError.noBaseURL }
        return await demo.settings()
    }
    func status() async throws -> MQTTBridgeStatus { await demo.status() }
    func save(_ patch: MQTTSettingsPatch) async throws {
        writes += 1
        if failWrite { throw APIError.noBaseURL }
        await demo.save(patch)
    }
    func test(_ request: MQTTConnectionTest) async throws -> MQTTTestResult {
        if delayTest { await withCheckedContinuation { pendingTest = $0; testWaiters.forEach { $0.resume() }; testWaiters = [] } }
        return await demo.test(request)
    }
}
