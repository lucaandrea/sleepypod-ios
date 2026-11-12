import XCTest
@testable import Sleepypod

final class BedWidgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func example(zones: [BedWidgetSnapshot.Zone]? = nil, checkedAt: Date? = nil) -> BedWidgetSnapshot {
        .init(version: 1, assignment: "Both sides", zones: zones ?? [
            .init(id: "left", requestedF: 70, powered: true), .init(id: "right", requestedF: 88, powered: true)],
            nextWake: "Tomorrow at 7:00 AM", checkedAt: checkedAt ?? now)
    }
    func testSeparateSidesNeverCollapseDifferentTargets() {
        XCTAssertEqual(example().targetLabel, "70°F / 88°F")
        XCTAssertEqual(example(zones: [.init(id: "right", requestedF: 88, powered: true),
                                      .init(id: "left", requestedF: 70, powered: true)]).targetLabel, "70°F / 88°F")
        XCTAssertEqual(example(zones: [.init(id: "left", requestedF: 70, powered: true),
                                      .init(id: "right", requestedF: 70, powered: true)]).targetLabel, "70°F")
    }
    func testOffAndMissingTargetsAreExplicit() {
        XCTAssertEqual(example(zones: [.init(id: "left", requestedF: 70, powered: false)]).targetLabel, "Off")
        XCTAssertEqual(example(zones: [.init(id: "left", requestedF: nil, powered: nil)]).targetLabel, "—")
        XCTAssertEqual(example(zones: [.init(id: "left", requestedF: 70, powered: false),
                                      .init(id: "right", requestedF: 70, powered: true)]).targetLabel, "Off / 70°F")
    }
    func testPastExpiryAndFutureClockFailClosed() {
        XCTAssertTrue(example().isUsable(at: now))
        XCTAssertTrue(example().isUsable(at: now.addingTimeInterval(899)))
        XCTAssertFalse(example().isUsable(at: now.addingTimeInterval(900)))
        XCTAssertFalse(example().isUsable(at: now.addingTimeInterval(-1)))
        XCTAssertFalse(example().isUsable(at: Date(timeIntervalSince1970: .nan)))
    }
    func testInvalidOrDuplicateZonesCannotAppear() {
        for zones: [BedWidgetSnapshot.Zone] in [[], [.init(id: "middle", requestedF: 70, powered: true)],
            [.init(id: "left", requestedF: 111, powered: true)],
            [.init(id: "left", requestedF: 70, powered: true), .init(id: "left", requestedF: 70, powered: true)]] {
            XCTAssertFalse(example(zones: zones).isUsable(at: now))
        }
    }
    func testSavedWakeSurvivesOvernightWithoutClaimingCurrentTargets() {
        var snapshot = example()
        snapshot.wake = .init(side: "right", at: now.addingTimeInterval(9 * 3_600), timeZone: "America/Los_Angeles",
            warmingAt: now.addingTimeInterval(8.5 * 3_600), targetF: 105, vibrationSeconds: 20)
        let morning = now.addingTimeInterval(8 * 3_600)
        XCTAssertTrue(snapshot.isUsable(at: morning))
        XCTAssertFalse(snapshot.hasRecentTargets(at: morning))
        XCTAssertEqual(snapshot.savedWake(at: morning)?.side, "right")
        XCTAssertFalse(snapshot.isUsable(at: now.addingTimeInterval(9 * 3_600)))
    }
    func testSavedWakeExpiresAfterEighteenHoursAndDoesNotInventAnotherDay() {
        var snapshot = example()
        snapshot.wake = .init(side: "left", at: now.addingTimeInterval(2 * 86_400), timeZone: "UTC",
            warmingAt: nil, targetF: nil, vibrationSeconds: 20)
        XCTAssertNotNil(snapshot.savedWake(at: now.addingTimeInterval(18 * 3_600 - 1)))
        XCTAssertFalse(snapshot.isUsable(at: now.addingTimeInterval(18 * 3_600)))
        XCTAssertNil(snapshot.savedWake(at: now.addingTimeInterval(18 * 3_600)))
    }
    func testPassedOrMalformedWakeDoesNotBecomeAScheduledAlarm() {
        for wake in [
            BedRemoteWake(side: "left", at: now, timeZone: "UTC", warmingAt: nil, targetF: nil, vibrationSeconds: 20),
            .init(side: "middle", at: now.addingTimeInterval(1_000), timeZone: "UTC", warmingAt: nil, targetF: nil, vibrationSeconds: 20),
            .init(side: "left", at: now.addingTimeInterval(1_000), timeZone: "Unknown/Zone", warmingAt: nil, targetF: nil, vibrationSeconds: 20),
            .init(side: "left", at: now.addingTimeInterval(1_000), timeZone: "UTC", warmingAt: now, targetF: nil, vibrationSeconds: 20)] {
            var snapshot = example(); snapshot.wake = wake
            XCTAssertFalse(snapshot.isUsable(at: now))
        }
    }
    func testStoreExpiresClearsAndRejectsMalformedData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BedWidgetStore(directory: folder)
        XCTAssertNil(store.read(at: now))
        try store.save(example(), at: now)
        XCTAssertEqual(store.read(at: now), example())
        XCTAssertNil(store.read(at: now.addingTimeInterval(900)))
        try store.clear(); XCTAssertNil(store.read(at: now))
        try Data("invalid json".utf8).write(to: folder.appendingPathComponent("bed-status.json"))
        XCTAssertNil(store.read(at: now))
        try Data(repeating: 32, count: 8_193).write(to: folder.appendingPathComponent("bed-status.json"))
        XCTAssertNil(store.read(at: now))
    }
    func testMissingEntitlementDoesNotUseAnUnsharedFallback() {
        let store = BedWidgetStore(directory: nil)
        XCTAssertThrowsError(try store.save(example(), at: now))
        XCTAssertNil(store.read(at: now))
    }
    func testDeepLinkIsAnExactNavigationRequest() {
        XCTAssertTrue(BedWidgetRoute.accepts(BedWidgetRoute.url))
        for value in ["sleepypod-widget://tonight?temperature=105", "sleepypod-widget://tonight#left",
                      "sleepypod-widget://stop", "https://tonight", "sleepypod-widget://owner@tonight"] {
            XCTAssertFalse(BedWidgetRoute.accepts(URL(string: value)!))
        }
    }
    func testDisplayCopyContainsNoLeaseIdentityOrHealthData() throws {
        let text = String(data: try JSONEncoder().encode(example()), encoding: .utf8)!
        for key in ["lease", "token", "person", "endpoint", "heartRate", "sleepStage"] {
            XCTAssertFalse(text.contains("\"\(key)\""))
        }
    }
}

@MainActor final class BedWidgetSessionTests: XCTestCase {
    private var folder: URL!
    private var store: BedWidgetStore!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = BedWidgetStore(directory: folder)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    func testRefreshPublishesDisplayOnlyAndWithdrawalClears() async {
        let source = WidgetTestSource()
        let session = BedWidgetSession(source: source, store: store, now: { source.now }, reload: {})
        await session.refresh()
        XCTAssertEqual(store.read(at: source.now)?.targetLabel, "70°F")
        XCTAssertEqual(source.commands, 0)
        session.withdraw(); XCTAssertNil(store.read(at: source.now))
    }
    func testTransportAndAuthenticationFailuresWithdrawPreviousDisplay() async {
        for error in [URLError(.cannotConnectToHost), URLError(.userAuthenticationRequired)] {
            let source = WidgetTestSource()
            let session = BedWidgetSession(source: source, store: store, now: { source.now }, reload: {})
            await session.refresh(); XCTAssertNotNil(store.read(at: source.now))
            source.error = error
            await session.refresh(); XCTAssertNil(store.read(at: source.now))
        }
    }
    func testSlowReadCannotRepopulateAfterAccountSwitch() async {
        let source = WidgetTestSource(); source.hold = true
        let session = BedWidgetSession(source: source, store: store, now: { source.now }, reload: {})
        let task = Task { await session.refresh() }
        await source.waitForHold()
        source.context = ["new-account"]; session.withdraw()
        source.release(); await task.value
        XCTAssertNil(store.read(at: source.now))
    }
    func testContextMismatchIsRejectedEvenWithoutViewNotification() async {
        let source = WidgetTestSource(); source.hold = true
        let session = BedWidgetSession(source: source, store: store, now: { source.now }, reload: {})
        let task = Task { await session.refresh() }
        await source.waitForHold(); source.context = ["new-account"]
        source.release(); await task.value
        XCTAssertNil(store.read(at: source.now))
    }
    func testStaleAndExpiredHardwareReadingsWithdraw() async {
        for age in [16.0, 60.0] {
            let source = WidgetTestSource(); source.age = age
            let session = BedWidgetSession(source: source, store: store, now: { source.now }, reload: {})
            await session.refresh(); XCTAssertNil(store.read(at: source.now))
        }
    }
    func testNewSessionClearsPreviousAccountOnLaunch() async {
        let source = WidgetTestSource()
        let first = BedWidgetSession(source: source, store: store, now: { source.now }, reload: {})
        await first.refresh(); XCTAssertNotNil(store.read(at: source.now))
        _ = BedWidgetSession(source: source, store: store, now: { source.now }, reload: {})
        XCTAssertNil(store.read(at: source.now))
    }
}

@MainActor private final class WidgetTestSource: BedRemoteSource {
    var context = ["private-account"]
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var age: TimeInterval = 1
    var commands = 0
    var error: Error?
    var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func waitForHold() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func read() async throws -> BedRemoteReading {
        let expected = context
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return .init(context: expected, snapshot: .init(lease: UUID(), receivedAt: now,
            expiresAt: now.addingTimeInterval(30), observationAt: now.addingTimeInterval(-age),
            person: "Private name", assignment: "Right side", zones: [.init(id: "right", measuredF: 69, requestedF: 70, powered: true)],
            nextAlarm: "Tomorrow at 7:00 AM", canAdjust: false, canStop: true, explanation: nil))
    }
    func perform(_ request: BedRemoteRequest, reviewed: BedRemoteReading,
                 validateBeforeSubmit: @escaping @MainActor () throws -> Void) async throws -> String {
        commands += 1; throw BedRemoteFailure.unavailable
    }
}
