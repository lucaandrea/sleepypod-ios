import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class PersonalControlVaultTests: XCTestCase {
    func testParentWriterPreservesDraftsOtherAccountsAndControlReceiptsAcrossRefresh() async throws {
        let bed = try PersonalControlFixtures.currentBed(), session = try PersonalControlFixtures.session(for: bed)
        let endpoint = URL(string: "https://personal-parent.invalid")!
        var record = HouseholdConnectionRecord(id: UUID(), endpoint: endpoint, deviceSecret: String(repeating: "A", count: 43), identity: session)
        var draft = HouseholdPreferences.blank; draft.preferredTemperatureF = 71
        record.draftPreferences = draft; record.draftPreferencesRevision = 1
        let other = HouseholdConnectionRecord(id: UUID(), endpoint: endpoint, deviceSecret: String(repeating: "B", count: 43))
        let vault = PersonalParentVault(state: .init(connections: [record, other], selected: record.id))
        let defaults = UserDefaults(suiteName: "personal-parent-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let account = PersonalAccountServer(session: session), controls = PersonalTestServer(bed: bed, session: session)
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in account }, personalClient: { _ in controls },
                                        capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in XCTFail("Owner key must not be read"); return "" })
        await parent.refresh()
        let model = try XCTUnwrap(parent.temperature)
        await model.refresh(); await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        XCTAssertEqual(vault.state.connections.first?.draftPreferences, draft)
        XCTAssertEqual(vault.state.connections.last?.deviceSecret, other.deviceSecret)
        XCTAssertEqual(vault.state.connections.first?.personalControls?.count, 1)
        await parent.savePreferences(draft)
        XCTAssertNil(vault.state.connections.first?.draftPreferences)
        XCTAssertEqual(vault.state.connections.first?.personalControls?.first?.receipt?.state, "acknowledged")
        XCTAssertTrue(parent.temperature === model)
        parent.signOut()
        XCTAssertNil(parent.temperature); XCTAssertFalse(model.canAdjust)
        await model.submit(.init(kind: "power", powered: false))
        let posts = await controls.posts; XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(vault.state.connections.first?.personalControls?.count, 1)
    }
    func testOldVaultRecordsDecodeWithoutControlHistoryAndFailedSaveBlocksDispatch() async throws {
        let bed = try PersonalControlFixtures.currentBed(), session = try PersonalControlFixtures.session(for: bed)
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://personal-parent.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
        let data = try JSONEncoder().encode(HouseholdVaultState(connections: [record], selected: record.id))
        let restored = try JSONDecoder().decode(HouseholdVaultState.self, from: data)
        XCTAssertNil(restored.connections.first?.personalControls)
        let vault = PersonalParentVault(state: restored)
        let defaults = UserDefaults(suiteName: "personal-parent-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let account = PersonalAccountServer(session: session), controls = PersonalTestServer(bed: bed, session: session)
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in account }, personalClient: { _ in controls },
                                        capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        await parent.refresh(); let model = try XCTUnwrap(parent.temperature); await model.refresh()
        vault.reject = true
        await model.submit(.init(kind: "power", powered: true))
        let posts = await controls.posts; XCTAssertTrue(posts.isEmpty)
        XCTAssertNil(vault.state.connections.first?.personalControls)
    }
    func testRevocationKeepsOnlyMinimalRecoveryThenExplicitRepairCanReadWithoutReplay() async throws {
        let bed = try PersonalControlFixtures.currentBed(), session = try PersonalControlFixtures.session(for: bed)
        var record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://personal-parent.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
        record.draftPreferences = .blank
        let vault = PersonalParentVault(state: .init(connections: [record], selected: record.id))
        let defaults = UserDefaults(suiteName: "personal-recovery-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let account = PersonalAccountServer(session: session), controls = PersonalTestServer(bed: bed, session: session)
        await controls.configure(postFailure: .uncertain)
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in account }, personalClient: { connection in
            XCTAssertEqual(connection.session.identity, session.identity); return controls
        }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in XCTFail("Owner fallback"); return "" }, secret: { String(repeating: "B", count: 43) })
        await parent.refresh(); let model = try XCTUnwrap(parent.temperature); await model.refresh()
        await model.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        let request = try XCTUnwrap(vault.state.connections.first?.personalControls?.first?.request)
        await controls.configure(sessionFailure: .authentication); await model.refresh()
        XCTAssertTrue(vault.state.connections.isEmpty); XCTAssertNil(vault.state.selected)
        XCTAssertNil(parent.temperature); XCTAssertTrue(parent.controlRecoveries.isEmpty)
        let marker = try XCTUnwrap(vault.state.controlTombstones?.first)
        XCTAssertEqual(marker.id, request.requestId); XCTAssertEqual(marker.identity, session.identity)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(marker)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["identity", "requestId", "expiresAt", "unresolvedState"])
        let serialized = String(decoding: try JSONEncoder().encode(vault.state), as: UTF8.self)
        XCTAssertFalse(serialized.contains(record.deviceSecret)); XCTAssertFalse(serialized.contains("temperatureF")); XCTAssertFalse(serialized.contains("draftPreferences"))
        await parent.reconcileControlRecovery(marker.id)
        var reads = await controls.lookups; XCTAssertTrue(reads.isEmpty)
        await controls.configure()
        await account.configure(token: String(repeating: "B", count: 43))
        await parent.start(address: record.endpoint.absoluteString, name: session.person.displayName, deviceName: "Repaired phone", invitation: String(repeating: "C", count: 43))
        XCTAssertEqual(parent.selected?.deviceSecret, String(repeating: "B", count: 43))
        XCTAssertEqual(parent.controlRecoveries.count, 1)
        let repaired = try XCTUnwrap(parent.temperature); await repaired.refresh()
        XCTAssertFalse(repaired.canAdjust); XCTAssertTrue(repaired.canStopPower)
        await parent.reconcileControlRecovery(marker.id)
        reads = await controls.lookups; XCTAssertEqual(reads, [request.requestId])
        let posts = await controls.posts; XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(parent.controlRecoveries.isEmpty); XCTAssertTrue(repaired.canAdjust)
        XCTAssertTrue(parent.notice?.contains("Controller acknowledged") == true)
        XCTAssertTrue(vault.state.connections.first?.personalControls?.isEmpty ?? true)
    }

    func testRecoveryNeverMatchesAnotherAccountAndSignOutDiscardsLateReceipt() async throws {
        let bed = try PersonalControlFixtures.currentBed(), session = try PersonalControlFixtures.session(for: bed)
        let request = try PersonalControlRequest(scope: bed.scope, action: .init(kind: "power", powered: false), now: PersonalControlFixtures.instant)
        let marker = PersonalControlTombstone(identity: session.identity, requestId: request.requestId, expiresAt: request.expiresAt, unresolvedState: "unknown")
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://personal-parent.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
        var foreignObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        foreignObject["accountId"] = UUID().uuidString
        let foreignSession = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: foreignObject))
        let foreign = HouseholdConnectionRecord(id: UUID(), endpoint: record.endpoint, deviceSecret: record.deviceSecret, identity: foreignSession)
        let vault = PersonalParentVault(state: .init(connections: [record, foreign], selected: foreign.id, controlTombstones: [marker]))
        let defaults = UserDefaults(suiteName: "personal-recovery-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let account = PersonalAccountServer(session: foreignSession), controls = PersonalTestServer(bed: bed, session: session)
        await controls.setReceipt(PersonalControlFixtures.receipt(request, zones: [.left, .right]))
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in account }, personalClient: { _ in controls }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        await parent.refresh(); XCTAssertTrue(parent.controlRecoveries.isEmpty)
        await parent.reconcileControlRecovery(marker.id)
        var reads = await controls.lookups; XCTAssertTrue(reads.isEmpty)
        await account.configure(session: session); await parent.select(record.id)
        XCTAssertEqual(parent.controlRecoveries, [marker])
        await controls.hold("receipt")
        let operation = Task { await parent.reconcileControlRecovery(marker.id) }
        await controls.waitHeld(); parent.signOut(); await controls.release(); await operation.value
        XCTAssertTrue(parent.controlRecoveries.isEmpty); XCTAssertNil(parent.notice)
        XCTAssertEqual(vault.state.controlTombstones, [marker])
        reads = await controls.lookups; XCTAssertEqual(reads, [marker.id])
        parent.erasePersonalLocalData()
        XCTAssertTrue(vault.state.connections.isEmpty); XCTAssertNil(vault.state.controlTombstones)
    }

    func testRecoveryCapacityBlocksNewPostWithoutEvictingExecutingEvidence() async throws {
        let bed = try PersonalControlFixtures.currentBed(), session = try PersonalControlFixtures.session(for: bed)
        let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://personal-parent.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
        var otherIdentity = session.identity; otherIdentity[2] = UUID().uuidString
        let markers = (0..<PersonalControlTombstone.capacity).map { _ in PersonalControlTombstone(identity: otherIdentity, requestId: UUID(), expiresAt: 1_793_314_830_000, unresolvedState: "executing") }
        let vault = PersonalParentVault(state: .init(connections: [record], selected: record.id, controlTombstones: markers))
        let defaults = UserDefaults(suiteName: "personal-recovery-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let account = PersonalAccountServer(session: session), controls = PersonalTestServer(bed: bed, session: session)
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in account }, personalClient: { _ in controls }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        await parent.refresh(); let model = try XCTUnwrap(parent.temperature); await model.refresh()
        await model.submit(.init(kind: "power", powered: true))
        let posts = await controls.posts; XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(vault.state.controlTombstones, markers); XCTAssertNotNil(model.error)
    }

}

@MainActor private final class PersonalParentVault: HouseholdVault {
    var state: HouseholdVaultState
    var reject = false
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws {
        if reject { throw HouseholdFailure.storage }; self.state = state
    }
}

private actor PersonalAccountServer: HouseholdTransport {
    var session: HouseholdSession
    var revoked = false
    var acceptedToken = String(repeating: "A", count: 43)
    var preferences = HouseholdPreferences.blank
    var revision = 1
    init(session: HouseholdSession) { self.session = session }
    func configure(session: HouseholdSession? = nil, revoked: Bool = false, token: String = String(repeating: "A", count: 43)) {
        if let session { self.session = session }; self.revoked = revoked; acceptedToken = token
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        if revoked { throw HouseholdFailure.authentication }
        if path == "household/join" { XCTAssertNil(token); return try JSONEncoder().encode(session) }
        XCTAssertEqual(token, acceptedToken)
        switch path {
        case "household/session": return try JSONEncoder().encode(session)
        case "me/preferences":
            if method == "PUT", let body {
                struct Input: Decodable { let expectedRevision: Int; let preferences: HouseholdPreferences }
                let value = try JSONDecoder().decode(Input.self, from: body)
                preferences = value.preferences; revision = value.expectedRevision + 1
            }
            return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: session.selfSleeperId, revision: revision, preferences: preferences))
        case "me/routines": return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: session.selfSleeperId, revision: 1, status: "draft_only", routines: []))
        case "household/devices": return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Fixture phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8)
        case "household/invitations": return Data(#"{"invitations":[]}"#.utf8)
        default: XCTFail("Unexpected personal account route"); throw HouseholdFailure.invalid
        }
    }
}
