import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor private final class AudioWorkspaceStore: BedtimeRitualStoring {
    var value: BedtimeRitualSavedState?
    func load(scope: String) throws -> BedtimeRitualSavedState? { value }
    func save(_ state: BedtimeRitualSavedState) throws { value = state }
}
@MainActor private final class AudioWorkspaceFlags {
    var current = true
    var fail = true
}

@MainActor final class BedtimeRitualWorkspaceTests: XCTestCase {
    private func session(current: @escaping @MainActor () -> Bool = { true }) -> BedtimeRitualSession {
        let scope = "bedtime-workspace-test-account"
        let model = BedtimeRitualSession(scope: scope, storage: AudioWorkspaceStore(), current: current,
            foreground: { true }, quiet: {
                let generatedAt = Date.now
                return .init(scope: scope, generatedAt: generatedAt,
                    expiresAt: generatedAt.addingTimeInterval(15), paused: false, until: nil)
            }, open: { _ in true })
        model.restore()
        model.confirmSetup(.init(revision: UUID(), mode: .sleep, startShortcut: "Sleep", pauseShortcut: "Pause",
            speakerName: "Example speakers", volumePercent: 35, durationMinutes: 60))
        return model
    }
    func testReopeningRetainsThePendingCallbackInsteadOfRestoringIt() async throws {
        let model = session(); var connections = 0
        let workspace = BedtimeRitualWorkspace { connections += 1; return model }
        await workspace.open(); await model.launch(.start); workspace.presented = false
        XCTAssertNil(model.error)
        await workspace.open()
        XCTAssertEqual(connections, 1); XCTAssertTrue(workspace.session === model)
        XCTAssertEqual(model.state?.attempt?.outcome, .handedOff)
        let callback = try BedtimeRitualURL.callback(XCTUnwrap(model.state?.attempt), result: "completed")
        XCTAssertTrue(workspace.receive(callback)); XCTAssertTrue(workspace.presented)
        XCTAssertEqual(model.state?.attempt?.outcome, .shortcutCompleted); XCTAssertNil(model.state?.attempt?.playback)
        XCTAssertFalse(workspace.receive(callback))
    }
    func testAccountChangeClearsVisibleStateAndRejectsTheOldReturn() async throws {
        let flags = AudioWorkspaceFlags()
        let model = session { flags.current }, workspace = BedtimeRitualWorkspace { self.session() }
        let bound = BedtimeRitualWorkspace { model }
        await bound.open(); await model.launch(.start)
        let callback = try BedtimeRitualURL.callback(XCTUnwrap(model.state?.attempt), result: "completed")
        flags.current = false; bound.checkAccount()
        XCTAssertNil(bound.session); XCTAssertTrue(model.invalidated); XCTAssertFalse(bound.receive(callback))
        XCTAssertFalse(workspace.receive(callback)); XCTAssertFalse(workspace.presented)
    }
    func testWithdrawalDuringConnectionCannotPublishTheOldAccount() async {
        let model = session()
        var continuation: CheckedContinuation<Void, Never>?
        let workspace = BedtimeRitualWorkspace { await withCheckedContinuation { continuation = $0 }; return model }
        let task = Task { await workspace.open() }
        while continuation == nil { await Task.yield() }
        workspace.withdraw(); continuation?.resume(); await task.value
        XCTAssertNil(workspace.session); XCTAssertTrue(model.invalidated); XCTAssertFalse(workspace.busy)
    }
    func testConnectionFailureHasExplicitRetryAndNoMediaEffect() async {
        let flags = AudioWorkspaceFlags()
        let model = session()
        let workspace = BedtimeRitualWorkspace { if flags.fail { throw URLError(.timedOut) }; return model }
        await workspace.open(); XCTAssertNotNil(workspace.error); XCTAssertNil(workspace.session)
        flags.fail = false; await workspace.prepare()
        XCTAssertNil(workspace.error); XCTAssertTrue(workspace.session === model); XCTAssertNil(model.state?.attempt)
    }
    func testMissingConnectionAndAccountWithdrawalHaveDifferentRecovery() async {
        let flags = AudioWorkspaceFlags()
        let workspace = BedtimeRitualWorkspace(personalContext: { !flags.current }) { throw BedtimeRitualFailure.connectionRequired }
        await workspace.open()
        XCTAssertEqual(workspace.error, BedtimeRitualFailure.connectionRequired.errorDescription)
        XCTAssertTrue(workspace.connectionInstructions.contains("Settings → Pod connection"))
        flags.current = false; workspace.withdraw()
        XCTAssertEqual(workspace.error, BedtimeRitualFailure.accountChanged.errorDescription)
        XCTAssertTrue(workspace.connectionInstructions.contains("Personal connections on this device"))
        XCTAssertNil(workspace.session)
    }
    func testIntentQueuesOnlyAnOpenAndCanBeConsumedOnce() async throws {
        let route = BedtimeRitualIntentRoute.shared
        _ = route.consume()
        _ = try await OpenBedtimeAudioIntent().perform()
        XCTAssertNotNil(route.request); XCTAssertTrue(route.consume()); XCTAssertFalse(route.consume())
    }
    func testPresentationNeverTurnsShortcutCompletionIntoPlayback() async throws {
        let model = session(); await model.launch(.start)
        let callback = try BedtimeRitualURL.callback(XCTUnwrap(model.state?.attempt), result: "completed")
        XCTAssertTrue(model.receive(callback))
        let attempt = try XCTUnwrap(model.state?.attempt)
        XCTAssertEqual(attempt.resultTitle, "Shortcut reported completion")
        XCTAssertTrue(attempt.resultDetail.contains("does not verify")); XCTAssertNil(attempt.playback)
        XCTAssertTrue(attempt.canRequestPause(at: attempt.createdAt.addingTimeInterval(60)))
        XCTAssertFalse(attempt.canRequestPause(at: attempt.createdAt.addingTimeInterval(12 * 3600)))
    }
    func testPauseCompletionNeverConfirmsAudioStopped() async throws {
        let model = session(); await model.launch(.start)
        await model.launch(.pause, confirmsCurrentAudio: true)
        let callback = try BedtimeRitualURL.callback(XCTUnwrap(model.state?.attempt), result: "completed")
        XCTAssertTrue(model.receive(callback))
        let attempt = try XCTUnwrap(model.state?.attempt)
        XCTAssertEqual(attempt.resultTitle, "Shortcut reported completion")
        XCTAssertTrue(attempt.resultDetail.contains("does not confirm it stopped"))
        XCTAssertFalse(attempt.resultDetail.contains("volume"))
        XCTAssertEqual(attempt.unconfirmedObservation, "Stopping the audio has not been confirmed.")
        XCTAssertNil(attempt.playback)
        model.observe(.stopped)
        XCTAssertEqual(model.state?.attempt?.playback?.observation, .stopped)
    }
    func testPersonalSessionSurvivesShortcutsBackgroundButNotSignOut() async throws {
        let (household, record) = try await personal()
        let audio = try household.bedtimeAudioSession()
        XCTAssertTrue(audio.available)
        let context = household.bedtimeAudioContext
        await household.sceneChanged(active: false)
        XCTAssertEqual(context, household.bedtimeAudioContext); XCTAssertTrue(audio.available)
        household.signOut(); XCTAssertFalse(audio.available)
        try BedtimeRitualConnection.removePersonalData(record: record)
    }
    func testErasingPersonalDataRemovesItsAudioSetup() async throws {
        let (household, record) = try await personal()
        let audio = try household.bedtimeAudioSession()
        let scope = audio.scope
        let value = BedtimeRitualSavedState(version: 1, scope: scope)
        try BedtimeRitualVault().save(value)
        XCTAssertNotNil(try BedtimeRitualVault().load(scope: scope))
        household.erasePersonalLocalData()
        XCTAssertNil(try BedtimeRitualVault().load(scope: scope)); XCTAssertFalse(audio.available)
        XCTAssertTrue(household.savedConnections.isEmpty)
        try BedtimeRitualConnection.removePersonalData(record: record)
    }
    private func personal() async throws -> (HouseholdWorkspace, HouseholdConnectionRecord) {
        let quiet = try PersonalQuietPreviewServer(mode: "idle"), server = try HouseholdTestServer()
        try await server.useSession(quiet.account)
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://ritual-fixture.invalid")!,
            deviceSecret: String(repeating: "A", count: 43), identity: quiet.account)
        let vault = HouseholdTestVault(); vault.state = .init(connections: [record], selected: record.id)
        let defaults = UserDefaults(suiteName: "audio-boundary-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let workspace = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, quietClient: { _ in quiet }, capability: { false })
        await workspace.refresh()
        return (workspace, record)
    }
}
