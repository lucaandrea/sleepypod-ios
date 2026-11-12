import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class PersonalBedRemoteTests: XCTestCase {
    private struct Fixture {
        let workspace: HouseholdWorkspace
        let source: PhoneBedRemoteSource
        let transport: RemoteWakeTransport
        let controls: PersonalTestServer
        let owner: UnusedOwnerRemote
        let vault: HouseholdTestVault
    }
    private func setup(lockedAtLaunch: Bool = false) throws -> Fixture {
        let bed = try PersonalControlFixtures.currentBed(), session = try PersonalControlFixtures.session(for: bed)
        let vault = HouseholdTestVault(), record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://personal.invalid")!,
            deviceSecret: String(repeating: "A", count: 43), identity: session)
        vault.state.connections = [record]; vault.state.selected = record.id
        vault.rejectLoad = lockedAtLaunch
        let original = try JSONDecoder().decode(PersonalNextWake.self, from: PersonalControlFixtures.data("wake", file: "personal-next-wake-v1"))
        let wake = PersonalNextWake(version: 1, scope: bed.scope, sourceSide: .left,
            observedAt: Int64(Date().timeIntervalSince1970 * 1_000), plan: original.plan, effect: "read_only")
        let transport = RemoteWakeTransport(session: session, wake: wake), controls = PersonalTestServer(bed: bed, session: session)
        let defaults = UserDefaults(suiteName: "remote-account-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let workspace = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in transport }, personalClient: { _ in controls })
        let owner = UnusedOwnerRemote(), source = PhoneBedRemoteSource(household: workspace, owner: owner)
        return .init(workspace: workspace, source: source, transport: transport, controls: controls, owner: owner, vault: vault)
    }
    func testPersonalRemoteUsesOwnWakeAndDurableCommandWithoutOwnerFallback() async throws {
        let fixture = try setup(), reading = try await fixture.source.read()
        XCTAssertTrue(reading.snapshot.nextAlarm.contains("105°F"))
        XCTAssertTrue(reading.snapshot.nextAlarm.contains("20 seconds"))
        XCTAssertEqual(reading.snapshot.zones.map(\.id), ["left", "right"])
        XCTAssertEqual(reading.snapshot.zones.map(\.requestedF), [68, 80])
        _ = try await fixture.source.perform(.init(action: .temperature, lease: reading.snapshot.lease, temperatureF: 70),
            reviewed: reading, validateBeforeSubmit: {})
        let posts = await fixture.controls.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(fixture.vault.state.connections.first?.personalControls?.first?.receipt?.state, "acknowledged")
        XCTAssertEqual(fixture.owner.reads, 0); XCTAssertEqual(fixture.owner.writes, 0)
        let calls = await fixture.transport.calls
        XCTAssertTrue(calls.allSatisfy { $0.method == "GET" && $0.token == String(repeating: "A", count: 43) })
    }
    func testMissingWakeDoesNotInventAnAlarmOrUseOwnerCredentials() async throws {
        let fixture = try setup()
        await fixture.transport.failWake(URLError(.cannotFindHost))
        let reading = try await fixture.source.read()
        XCTAssertTrue(reading.snapshot.nextAlarm.contains("unavailable"))
        XCTAssertFalse(reading.snapshot.nextAlarm.contains("7:00"))
        XCTAssertTrue(reading.snapshot.canStop)
        XCTAssertEqual(fixture.owner.reads, 0)
    }
    func testAuthenticationFailureCannotReturnAReadOrFallBackToOwner() async throws {
        let fixture = try setup()
        await fixture.transport.failWake(HouseholdFailure.authentication)
        do { _ = try await fixture.source.read(); XCTFail("Revoked personal credentials must withhold the snapshot") }
        catch { XCTAssertEqual(error as? HouseholdFailure, .authentication) }
        XCTAssertEqual(fixture.owner.reads, 0)
        let posts = await fixture.controls.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testSignOutDuringWakeReadDiscardsPrivateResult() async throws {
        let fixture = try setup()
        await fixture.transport.holdWake()
        let read = Task { try await fixture.source.read() }
        await fixture.transport.waitHeld(); fixture.workspace.signOut(); await fixture.transport.release()
        do { _ = try await read.value; XCTFail("The previous account must not be presented") }
        catch { XCTAssertEqual(error as? HouseholdFailure, .changedIdentity) }
        XCTAssertEqual(fixture.owner.reads, 0)
    }
    func testBackgroundReadCanUseCurrentAccountButReceiptStorageMustSucceedBeforeDispatch() async throws {
        let fixture = try setup()
        await fixture.workspace.sceneChanged(active: false)
        let reading = try await fixture.source.read()
        fixture.vault.reject = true
        do {
            _ = try await fixture.source.perform(.init(action: .temperature, lease: reading.snapshot.lease, temperatureF: 70),
                reviewed: reading, validateBeforeSubmit: {})
            XCTFail("Unavailable secure storage must prevent a command")
        } catch {}
        let posts = await fixture.controls.posts; XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(fixture.owner.writes, 0)
    }
    func testLockedLaunchRecoversSameAccountOnFirstBackgroundRefreshAfterUnlock() async throws {
        let fixture = try setup(lockedAtLaunch: true), coordinator = BedRemoteCoordinator(source: fixture.source)
        let savedID = fixture.vault.state.selected
        await fixture.workspace.sceneChanged(active: false)
        let locked = await coordinator.handle(.init(action: .refresh))
        XCTAssertEqual(locked.outcome, .withheld)
        XCTAssertNil(locked.snapshot); XCTAssertNil(fixture.workspace.selected)
        XCTAssertEqual(fixture.vault.saveCount, 0)
        let lockedCalls = await fixture.transport.calls; XCTAssertTrue(lockedCalls.isEmpty)
        fixture.vault.rejectLoad = false
        let recovered = await coordinator.handle(.init(action: .refresh))
        XCTAssertEqual(recovered.outcome, .snapshot)
        XCTAssertNotNil(recovered.snapshot)
        XCTAssertEqual(fixture.workspace.selected?.id, savedID)
        XCTAssertEqual(fixture.vault.state.connections.count, 1)
        XCTAssertEqual(fixture.vault.state.connections.first?.deviceSecret, String(repeating: "A", count: 43))
        XCTAssertEqual(fixture.owner.reads, 0); XCTAssertEqual(fixture.owner.writes, 0)
        let posts = await fixture.controls.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testRepeatedUnavailableVaultNeverOverwritesOrUsesOwnerAccount() async throws {
        let fixture = try setup(lockedAtLaunch: true), coordinator = BedRemoteCoordinator(source: fixture.source)
        let savedID = fixture.vault.state.selected
        for _ in 0..<3 {
            let reply = await coordinator.handle(.init(action: .refresh))
            XCTAssertEqual(reply.outcome, .withheld)
        }
        XCTAssertEqual(fixture.vault.state.selected, savedID)
        XCTAssertEqual(fixture.vault.state.connections.count, 1)
        XCTAssertEqual(fixture.vault.saveCount, 0)
        XCTAssertEqual(fixture.owner.reads, 0); XCTAssertEqual(fixture.owner.writes, 0)
        let calls = await fixture.transport.calls; XCTAssertTrue(calls.isEmpty)
        let posts = await fixture.controls.posts; XCTAssertTrue(posts.isEmpty)
    }
}

private actor RemoteWakeTransport: HouseholdTransport {
    struct Call { let method: String; let token: String? }
    let session: HouseholdSession
    let wake: PersonalNextWake
    var calls: [Call] = []
    private var failure: (any Error)?
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(session: HouseholdSession, wake: PersonalNextWake) { self.session = session; self.wake = wake }
    func failWake(_ error: any Error) { failure = error }
    func holdWake() { held = true }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        calls.append(.init(method: method, token: token))
        if path == "household/session" { return try JSONEncoder().encode(session) }
        guard path == "me/alarm/next", method == "GET" else { throw HouseholdFailure.invalid }
        if held { held = false; await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        return try JSONEncoder().encode(wake)
    }
}

@MainActor private final class UnusedOwnerRemote: BedRemoteSource {
    var context: [String] { ["owner must not be used"] }
    var reads = 0, writes = 0
    func read() async throws -> BedRemoteReading { reads += 1; throw BedRemoteFailure.unavailable }
    func perform(_ request: BedRemoteRequest, reviewed: BedRemoteReading, validateBeforeSubmit: @escaping @MainActor () throws -> Void) async throws -> String {
        writes += 1; throw BedRemoteFailure.unavailable
    }
}
