import XCTest
@testable import Sleepypod

@MainActor private final class RitualMemory: BedtimeRitualStoring {
    var values: [String: BedtimeRitualSavedState] = [:]
    var failRead = false
    var failSave = false
    func load(scope: String) throws -> BedtimeRitualSavedState? {
        if failRead { throw BedtimeRitualFailure.storage }
        return values[scope]
    }
    func save(_ value: BedtimeRitualSavedState) throws {
        if failSave { throw BedtimeRitualFailure.storage }
        values[value.scope] = value
    }
}

@MainActor private final class RitualHarness {
    let scope = "owner-installation-account-revision-001"
    let storage = RitualMemory()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 1000
    var current = true
    var foreground = true
    var paused = false
    var quietFailed = false
    var opened = true
    var urls: [URL] = []
    var readCount = 0
    var onRead: (() async -> Void)?
    var onOpen: ((URL) async -> Void)?
    var mutateQuiet: ((BedtimeRitualQuiet) -> BedtimeRitualQuiet)?
    lazy var model = makeModel()
    let plan = BedtimeRitualPlan(revision: UUID(), mode: .sleep, startShortcut: "Bedtime & Sleep / 演奏?",
        pauseShortcut: "Pause bedroom", speakerName: "Bedside HomePods", volumePercent: 35, durationMinutes: 60)
    func makeModel(scope: String? = nil) -> BedtimeRitualSession {
        BedtimeRitualSession(scope: scope ?? self.scope, storage: storage, current: { self.current }, foreground: { self.foreground },
            quiet: {
                self.readCount += 1
                let value = BedtimeRitualQuiet(scope: self.scope, generatedAt: self.clock, expiresAt: self.clock.addingTimeInterval(15),
                    paused: self.paused, until: self.paused ? self.clock.addingTimeInterval(3600) : nil)
                await self.onRead?()
                if self.quietFailed { throw URLError(.timedOut) }
                return self.mutateQuiet?(value) ?? value
            }, open: { url in
                self.urls.append(url)
                await self.onOpen?(url)
                return self.opened
            }, now: { self.clock }, uptime: { self.uptime })
    }
    func ready() { model.restore(); model.confirmSetup(plan) }
    func advance(_ seconds: TimeInterval) { clock.addTimeInterval(seconds); uptime += seconds }
    func callback(_ result: String = "completed") throws -> URL {
        try BedtimeRitualURL.callback(XCTUnwrap(model.state?.attempt), result: result)
    }
}

@MainActor final class BedtimeRitualTests: XCTestCase {
    func testHandoffSavesBeforeOpeningAndDoesNotClaimPlayback() async throws {
        let fixture = RitualHarness(); fixture.ready()
        fixture.onOpen = { _ in
            XCTAssertEqual(fixture.storage.values[fixture.scope]?.attempt?.outcome, .opening)
        }
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.urls.count, 1)
        XCTAssertEqual(fixture.model.state?.attempt?.outcome, .handedOff)
        XCTAssertNil(fixture.model.state?.attempt?.playback)
        XCTAssertTrue(fixture.model.receive(try fixture.callback()))
        XCTAssertEqual(fixture.model.state?.attempt?.outcome, .shortcutCompleted)
        XCTAssertNil(fixture.model.state?.attempt?.playback)
        fixture.model.observe(.heardOnSelectedSpeakers)
        XCTAssertEqual(fixture.model.state?.attempt?.playback?.observation, .heardOnSelectedSpeakers)
    }
    func testURLPreservesUnicodeAndReservedCharactersWithoutPrivateContext() async throws {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        let parts = try XCTUnwrap(URLComponents(url: XCTUnwrap(fixture.urls.first), resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "shortcuts"); XCTAssertEqual(parts.host, "x-callback-url")
        XCTAssertEqual(parts.path, "/run-shortcut")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["name"], fixture.plan.startShortcut)
        XCTAssertEqual(Set(items.keys), ["name", "input", "text", "x-success", "x-cancel", "x-error"])
        let input = try JSONDecoder().decode(BedtimeRitualURL.Input.self, from: Data(XCTUnwrap(items["text"]).utf8))
        XCTAssertEqual(input.volumePercent, 35); XCTAssertEqual(input.durationMinutes, 60)
        XCTAssertEqual(input.speakerName, fixture.plan.speakerName); XCTAssertEqual(input.action, .start)
        XCTAssertFalse(parts.url!.absoluteString.contains(fixture.scope))
        XCTAssertFalse(items["text"]!.contains("token"))
    }
    func testPendingAndCompletedResultsNeverReplayWithoutExplicitReview() async throws {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.urls.count, 1)
        XCTAssertTrue(fixture.model.receive(try fixture.callback()))
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.urls.count, 1)
        fixture.model.acknowledgeResult()
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.urls.count, 2)
    }
    func testRestoringInFlightHandoffShowsUnknownAndCannotReplayOrAcceptOldCallback() async throws {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        let callback = try fixture.callback()
        let restored = fixture.makeModel(); restored.restore()
        XCTAssertEqual(restored.state?.attempt?.outcome, .unknown)
        XCTAssertFalse(restored.receive(callback))
        await restored.launch(.start)
        XCTAssertEqual(fixture.urls.count, 1)
    }
    func testQuietRequestPreventsAudioAndDoesNotOverwriteSetup() async {
        let fixture = RitualHarness(); fixture.ready(); fixture.paused = true
        await fixture.model.launch(.start)
        XCTAssertTrue(fixture.urls.isEmpty); XCTAssertNil(fixture.model.state?.attempt)
        XCTAssertEqual(fixture.model.error, BedtimeRitualFailure.someoneResting.errorDescription)
    }
    func testQuietReadFailureAndUnavailableOrFutureReadingsDoNotOpenShortcuts() async {
        let fixture = RitualHarness(); fixture.ready(); fixture.quietFailed = true
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.model.error, BedtimeRitualFailure.quietUnavailable.errorDescription)
        fixture.quietFailed = false
        for offset in [-20.0, 6.0] {
            fixture.mutateQuiet = { value in .init(scope: value.scope, generatedAt: value.generatedAt.addingTimeInterval(offset),
                expiresAt: value.expiresAt.addingTimeInterval(offset), paused: false, until: nil) }
            await fixture.model.launch(.start)
        }
        XCTAssertTrue(fixture.urls.isEmpty)
    }
    func testSlowQuietReadAndReversedMonotonicClockWithholdLaunch() async {
        for elapsed in [15.0, -1.0] {
            let fixture = RitualHarness(); fixture.ready()
            fixture.onRead = { fixture.uptime += elapsed }
            await fixture.model.launch(.start)
            XCTAssertTrue(fixture.urls.isEmpty)
        }
    }
    func testAccountChangesDuringReadCannotLaunchOrExposePriorState() async {
        let fixture = RitualHarness(); fixture.ready()
        fixture.onRead = { fixture.current = false }
        await fixture.model.launch(.start)
        XCTAssertTrue(fixture.urls.isEmpty); XCTAssertNil(fixture.model.state); XCTAssertTrue(fixture.model.invalidated)
    }
    func testAppLeavingForegroundDuringReadWithholdsLaunch() async {
        let fixture = RitualHarness(); fixture.ready()
        fixture.onRead = { fixture.foreground = false }
        await fixture.model.launch(.start)
        XCTAssertTrue(fixture.urls.isEmpty)
        XCTAssertEqual(fixture.model.error, BedtimeRitualFailure.foregroundRequired.errorDescription)
    }
    func testConcurrentTapsLaunchOnlyOnce() async {
        let fixture = RitualHarness(); fixture.ready()
        fixture.onRead = { await fixture.model.launch(.start) }
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.readCount, 1); XCTAssertEqual(fixture.urls.count, 1)
    }
    func testInvalidationDuringReadPreventsOpeningAndLeavesNoBusyState() async {
        let fixture = RitualHarness(); fixture.ready()
        fixture.onRead = { fixture.model.invalidate() }
        await fixture.model.launch(.start)
        XCTAssertTrue(fixture.urls.isEmpty); XCTAssertFalse(fixture.model.busy); XCTAssertNil(fixture.model.state)
    }
    func testStorageFailureBeforeOpenWithholdsExternalEffect() async {
        let fixture = RitualHarness(); fixture.ready(); fixture.storage.failSave = true
        await fixture.model.launch(.start)
        XCTAssertTrue(fixture.urls.isEmpty); XCTAssertNil(fixture.model.state)
    }
    func testStorageFailureAfterOpenKeepsDurableUnknownRecoveryWithoutReplay() async {
        let fixture = RitualHarness(); fixture.ready()
        fixture.onOpen = { _ in fixture.storage.failSave = true }
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.urls.count, 1); XCTAssertNil(fixture.model.state)
        XCTAssertEqual(fixture.storage.values[fixture.scope]?.attempt?.outcome, .opening)
        fixture.storage.failSave = false
        let restored = fixture.makeModel(); restored.restore()
        XCTAssertEqual(restored.state?.attempt?.outcome, .unknown)
        await restored.launch(.start)
        XCTAssertEqual(fixture.urls.count, 1)
    }
    func testCallbackBeatingOpenCompletionPreservesReportedOutcome() async throws {
        let fixture = RitualHarness(); fixture.ready()
        fixture.onOpen = { _ in XCTAssertTrue(fixture.model.receive(try! fixture.callback())) }
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.model.state?.attempt?.outcome, .shortcutCompleted)
    }
    func testRejectedOpenIsExplicitAndStillNeedsReview() async {
        let fixture = RitualHarness(); fixture.ready(); fixture.opened = false
        await fixture.model.launch(.start)
        XCTAssertEqual(fixture.model.state?.attempt?.outcome, .notOpened)
        XCTAssertTrue(fixture.model.needsReview)
        await fixture.model.launch(.pause, confirmsCurrentAudio: true)
        XCTAssertEqual(fixture.urls.count, 1)
    }
    func testPauseRequiresUserToConfirmCurrentAudioButWorksDuringQuietTime() async throws {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        await fixture.model.launch(.pause)
        XCTAssertEqual(fixture.urls.count, 1)
        fixture.paused = true
        await fixture.model.launch(.pause, confirmsCurrentAudio: true)
        XCTAssertEqual(fixture.urls.count, 2); XCTAssertEqual(fixture.readCount, 1)
        XCTAssertEqual(fixture.model.state?.attempt?.action, .pause)
        XCTAssertTrue(fixture.model.receive(try fixture.callback()))
        XCTAssertNil(fixture.model.state?.attempt?.playback)
        fixture.model.observe(.stopped)
        XCTAssertEqual(fixture.model.state?.attempt?.playback?.observation, .stopped)
    }
    func testPauseDoesNotUseOldSessionsOrClaimStartObservation() async {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        fixture.advance(12 * 3600)
        await fixture.model.launch(.pause, confirmsCurrentAudio: true)
        XCTAssertEqual(fixture.urls.count, 1)
    }
    func testCallbacksCannotCrossAccountsOrRequestIDs() async throws {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        let callback = try fixture.callback()
        let other = fixture.makeModel(scope: "second-account-revision-002"); other.restore()
        XCTAssertFalse(other.receive(callback)); XCTAssertNil(other.state?.setup)
        var components = try XCTUnwrap(URLComponents(url: callback, resolvingAgainstBaseURL: false))
        components.queryItems?[0].value = UUID().uuidString.lowercased()
        XCTAssertFalse(fixture.model.receive(try XCTUnwrap(components.url)))
        fixture.current = false
        XCTAssertFalse(fixture.model.receive(callback)); XCTAssertNil(fixture.model.state)
    }
    func testExpiredAndClockAdjustedCallbacksCannotConfirmSuccess() async throws {
        for change in ["expired", "wall-reversed", "uptime-reversed", "uptime-expired"] {
            let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
            let callback = try fixture.callback()
            switch change {
            case "expired": fixture.advance(120)
            case "wall-reversed": fixture.clock.addTimeInterval(-1)
            case "uptime-reversed": fixture.uptime -= 1
            default: fixture.uptime += 120
            }
            XCTAssertFalse(fixture.model.receive(callback))
            fixture.model.expire()
            XCTAssertEqual(fixture.model.state?.attempt?.outcome, .unknown)
        }
    }
    func testCallbacksAreOneUseAndNeverMarkPhysicalPlayback() async throws {
        for result in ["completed", "cancelled", "failed"] {
            let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
            let callback = try fixture.callback(result)
            XCTAssertTrue(fixture.model.receive(callback))
            XCTAssertFalse(fixture.model.receive(callback))
            XCTAssertNil(fixture.model.state?.attempt?.playback)
        }
    }
    func testCallbackCannotInjectReturnDestinationsOrPrivateMessages() async throws {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        let attempt = try XCTUnwrap(fixture.model.state?.attempt)
        let original = try fixture.callback()
        for suffix in ["&nonce=other", "&next=https%3A%2F%2Fevil.invalid", "#fragment"] {
            XCTAssertNil(BedtimeRitualURL.outcome(URL(string: original.absoluteString + suffix)!, attempt: attempt))
        }
        let reported = URL(string: original.absoluteString + "&result=token%3Dprivate")!
        XCTAssertTrue(fixture.model.receive(reported))
        XCTAssertFalse(String(data: try JSONEncoder().encode(fixture.model.state), encoding: .utf8)!.contains("private"))
    }
    func testSetupCannotReplaceAnUnreviewedHandoff() async {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        let replacement = BedtimeRitualPlan(revision: UUID(), mode: .relax, startShortcut: "New bedtime", pauseShortcut: "New pause",
                                           speakerName: "New speakers", volumePercent: 20, durationMinutes: 30)
        fixture.model.confirmSetup(replacement)
        XCTAssertEqual(fixture.model.state?.setup?.plan, fixture.plan)
        fixture.model.acknowledgeResult(); fixture.model.confirmSetup(replacement)
        XCTAssertEqual(fixture.model.state?.setup?.plan, replacement); XCTAssertNil(fixture.model.state?.attempt)
    }
    func testMissingSetupAndFailedRestoreCannotLaunch() async {
        let fixture = RitualHarness(); fixture.model.restore()
        await fixture.model.launch(.start)
        fixture.ready(); fixture.storage.failRead = true; fixture.model.restore()
        await fixture.model.launch(.start)
        XCTAssertTrue(fixture.urls.isEmpty); XCTAssertNil(fixture.model.state)
    }
    func testSavedStateRefusesCrossAccountOrMismatchedSetup() async throws {
        let fixture = RitualHarness(); fixture.ready(); await fixture.model.launch(.start)
        var saved = try XCTUnwrap(fixture.model.state)
        XCTAssertThrowsError(try saved.validate(scope: "second-account-revision-002"))
        saved.setup = nil
        XCTAssertThrowsError(try saved.validate(scope: fixture.scope))
    }
    func testSecureVaultRoundTripIsAccountSpecific() throws {
        let vault = BedtimeRitualVault(service: "com.lucaandrea.freesleep.ritual-test.\(UUID().uuidString)")
        let fixture = RitualHarness()
        let state = BedtimeRitualSavedState(version: 1, scope: fixture.scope, setup: .init(plan: fixture.plan, reviewedAt: fixture.clock))
        defer { try? vault.remove(scope: fixture.scope) }
        try vault.save(state)
        XCTAssertEqual(try vault.load(scope: fixture.scope), state)
        XCTAssertNil(try vault.load(scope: "second-account-revision-002"))
        try vault.remove(scope: fixture.scope)
        XCTAssertNil(try vault.load(scope: fixture.scope))
    }
}
