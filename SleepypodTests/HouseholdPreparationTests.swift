import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class HouseholdPreparationTests: XCTestCase {
    private let endpoint = URL(string: "https://household.invalid")!
    private let invitation = String(repeating: "A", count: 43)
    private func workspace(_ server: HouseholdTestServer, vault: HouseholdTestVault = .init()) -> HouseholdWorkspace {
        let defaults = UserDefaults(suiteName: "household-tests-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        return .init(vault: vault, defaults: defaults, client: { _ in server }, capability: { true }, ownerEndpoint: { self.endpoint }, ownerKey: { _ in "test-owner-only" })
    }
    private func joined(_ server: HouseholdTestServer, vault: HouseholdTestVault = .init()) async -> HouseholdWorkspace {
        let model = workspace(server, vault: vault)
        await model.start(address: endpoint.absoluteString, name: "Example member", deviceName: "Example phone", invitation: invitation)
        return model
    }
    func testOwnerSetupRequiresExplicitReadyCapabilityBeforeGeneratingRequest() async throws {
        let server = try HouseholdTestServer(), model = workspace(server)
        await model.start(address: endpoint.absoluteString, name: "Owner", deviceName: "Phone", invitation: nil)
        let calls = await server.calls
        XCTAssertTrue(calls.isEmpty); XCTAssertNil(model.pending); XCTAssertNotNil(model.error)
    }
    func testPrivateDraftsRemainBoundToTheirVerifiedConnectionAndIdentity() async throws {
        let server = try HouseholdTestServer(), vault = HouseholdTestVault(), model = await joined(server, vault: vault)
        let first = try XCTUnwrap(model.selected)
        var draft = model.draftPreferences; draft.preferredTemperatureF = 70
        await server.failNext(.conflict); await model.savePreferences(draft)
        model.signOut()
        try await server.useOwner()
        await model.start(address: endpoint.absoluteString, name: "Another account", deviceName: "Phone", invitation: invitation)
        let second = try XCTUnwrap(model.selected)
        XCTAssertNotEqual(first.id, second.id); XCTAssertNotEqual(first.identity?.namespace, second.identity?.namespace)
        XCTAssertNotEqual(first.deviceSecret, second.deviceSecret)
        XCTAssertNil(second.draftPreferences); XCTAssertNotEqual(model.draftPreferences.preferredTemperatureF, 70)
        XCTAssertEqual(vault.state.connections.first { $0.id == first.id }?.draftPreferences, draft)
    }
    func testFutureScheduledRoutinesCannotBePresentedAsEditableDrafts() throws {
        let fixture = try HouseholdTestServer.fixture()
        let session = try JSONDecoder().decode(HouseholdSession.self, from: XCTUnwrap(fixture["memberSession"]))
        let live = HouseholdRoutinesResponse(sleeperId: session.selfSleeperId, revision: 1, status: "scheduled", routines: [])
        XCTAssertThrowsError(try live.validate(for: session)) { error in
            XCTAssertEqual(error as? HouseholdFailure, .preparationOnly)
        }
    }
    func testFrozenMemberAndOwnerContractsKeepAssignmentAndCapabilitiesExplicit() throws {
        let fixture = try HouseholdTestServer.fixture()
        for name in ["memberSession", "ownerSession"] {
            let session = try JSONDecoder().decode(HouseholdSession.self, from: XCTUnwrap(fixture[name]))
            try session.validate()
            XCTAssertFalse(session.capabilities.personalControls); XCTAssertFalse(session.capabilities.healthImport)
            XCTAssertFalse(session.capabilities.personalHistory); XCTAssertFalse(session.capabilities.activateArrangement)
            if name == "memberSession" {
                XCTAssertEqual(session.person.assignment, "unassigned"); XCTAssertTrue(session.person.zones.isEmpty)
                try JSONDecoder().decode(HouseholdPreferencesResponse.self, from: XCTUnwrap(fixture["preferences"])).validate(for: session)
                let week = try JSONDecoder().decode(HouseholdRoutinesResponse.self, from: XCTUnwrap(fixture["routines"]))
                try week.validate(for: session); XCTAssertEqual(week.status, "draft_only")
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture["memberSession"])) as? [String: Any])
        object["self"] = ["displayName": "Member", "assignment": "unassigned", "zones": ["left"]]
        let invalid = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try invalid.validate())
    }
    func testLostJoinSurvivesRelaunchAndReusesExactCredentialWithoutOwnerAuthorization() async throws {
        let server = try HouseholdTestServer(), vault = HouseholdTestVault()
        await server.failNext(.uncertain)
        let first = await joined(server, vault: vault)
        let body = try XCTUnwrap(first.pending?.body), secret = try XCTUnwrap(first.selected?.deviceSecret)
        XCTAssertTrue(HouseholdValidation.secret(secret)); XCTAssertEqual(secret.count, 43)
        let second = workspace(server, vault: vault)
        await second.retryPending()
        XCTAssertNil(second.pending); XCTAssertEqual(second.session?.person.assignment, "unassigned")
        let calls = await server.calls
        let joins = calls.filter { $0.path == "household/join" }
        XCTAssertEqual(joins.count, 2); XCTAssertEqual(joins.map(\.body), [body, body]); XCTAssertTrue(joins.allSatisfy { $0.token == nil })
        XCTAssertTrue(calls.filter { $0.method == "GET" }.allSatisfy { $0.token == secret })
        XCTAssertEqual(vault.state.connections.count, 1)
    }
    func testLostSetupReconcilesBySessionWithoutRepeatedSetupOrRotatedKey() async throws {
        let server = try HouseholdTestServer(), vault = HouseholdTestVault(), model = workspace(server, vault: vault)
        try await server.useOwner(); await server.failNext(.uncertain)
        await model.checkOwnerPreparation()
        await model.start(address: endpoint.absoluteString, name: "Owner", deviceName: "Phone", invitation: nil, sourceSide: .right)
        let secret = try XCTUnwrap(model.selected?.deviceSecret)
        XCTAssertEqual(model.pending?.kind, .setup)
        await model.refresh()
        XCTAssertNil(model.pending); XCTAssertEqual(model.session?.role, "owner")
        let calls = await server.calls, setup = try XCTUnwrap(calls.first)
        XCTAssertEqual(setup.token, "test-owner-only"); XCTAssertEqual(calls.filter { $0.path == "household/setup" }.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(setup.body)) as? [String: Any])
        XCTAssertEqual(payload["sourceSide"] as? String, "right"); XCTAssertEqual(payload["deviceSecret"] as? String, secret)
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0.token == secret })
    }
    func testStorageFailureStopsJoinBeforeAnyRequest() async throws {
        let server = try HouseholdTestServer(), vault = HouseholdTestVault(); vault.reject = true
        let model = await joined(server, vault: vault)
        let calls = await server.calls
        XCTAssertTrue(calls.isEmpty); XCTAssertNil(model.pending); XCTAssertNotNil(model.error)
    }
    func testDraftConflictRequiresRefreshAndExplicitReviewBeforeReplacingNewerData() async throws {
        let server = try HouseholdTestServer(), model = await joined(server)
        var preferences = model.draftPreferences; preferences.preferredTemperatureF = 70
        await server.failNext(.conflict)
        await model.savePreferences(preferences)
        XCTAssertNil(model.session); XCTAssertFalse(model.maySave); XCTAssertNil(model.pending)
        try await server.changePreferencesRevision(2)
        await model.refresh()
        XCTAssertTrue(model.needsDraftReview); XCTAssertFalse(model.maySave)
        XCTAssertEqual(model.draftPreferences.preferredTemperatureF, 70)
        model.reviewDrafts(keep: true); XCTAssertTrue(model.maySave)
        await model.savePreferences(model.draftPreferences)
        let calls = await server.calls, saved = try XCTUnwrap(calls.last { $0.method == "PUT" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(saved.body)) as? [String: Any])
        XCTAssertEqual(body["expectedRevision"] as? Int, 2)
        XCTAssertEqual(body["expectedAssignmentRevision"] as? Int, 1)
        XCTAssertNil(model.selected?.draftPreferences)
    }
    func testWeeklyDraftRoundTripPreservesFullAlarmAndNeverCallsScheduleRoute() async throws {
        let server = try HouseholdTestServer(), model = await joined(server)
        var night = BedtimeRoutineDraft.blank
        night.power.enabled = true; night.power.onTime = "22:00"; night.power.offTime = "07:00"
        night.temperatures = [.init(time: "01:00", temperature: 68, enabled: true)]
        night.alarm = .standard; night.alarm?.time = "07:00"; night.alarm?.snoozeDuration = 600; night.alarm?.snoozeTaper = 50
        let week = [HouseholdRoutine(dayOfWeek: .sunday, draft: night.normalized)]
        await model.saveRoutines(week)
        XCTAssertEqual(model.routines?.routines, week); XCTAssertEqual(model.routines?.status, "draft_only")
        XCTAssertNil(model.pending); XCTAssertNil(model.selected?.draftRoutines)
        let calls = await server.calls
        XCTAssertTrue(calls.allSatisfy { HouseholdHTTPClient.methods[$0.path] != nil })
        XCTAssertEqual(calls.filter { $0.method == "PUT" }.map(\.path), ["me/routines"])
        XCTAssertThrowsError(try HouseholdRoutine.validate(week + week))
    }
    func testInvitationSecretAndMutationRequestAreStableAfterLostResponse() async throws {
        let server = try HouseholdTestServer(), model = await joined(server)
        await server.failNext(.uncertain)
        await model.invite(kind: "own_device")
        let pending = try XCTUnwrap(model.pending)
        await model.retryPending()
        let calls = await server.calls.filter { $0.method == "POST" && $0.path == "household/invitations" }
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0].body, calls[1].body); XCTAssertEqual(calls[0].body, pending.body)
        XCTAssertEqual(model.selected?.invitationSecrets.count, 1)
        let before = await server.calls.count
        await model.invite(kind: "new_person")
        let after = await server.calls.count; XCTAssertEqual(before, after, "Members cannot create another person's invitation")
    }
    func testRevokingCurrentDeviceRemovesCredentialAndKeepsPersonalBoundary() async throws {
        let server = try HouseholdTestServer(), vault = HouseholdTestVault(), model = await joined(server, vault: vault)
        let device = try XCTUnwrap(model.devices.first)
        await model.revoke(deviceId: device.id)
        XCTAssertNotNil(model.selected, "The last paired device cannot be revoked")
        try await server.addOtherDevice(); await model.refresh()
        await model.revoke(deviceId: device.id)
        XCTAssertNil(model.session); XCTAssertNil(model.selected); XCTAssertTrue(vault.state.connections.isEmpty)
        XCTAssertTrue(model.active)
    }
    func testRemoteRevocationClearsLocalCredentialAndNeverReturnsToOwner() async throws {
        let server = try HouseholdTestServer(), model = await joined(server)
        await server.failNext(.authentication); await model.refresh()
        XCTAssertNil(model.session); XCTAssertNil(model.selected); XCTAssertTrue(model.active)
    }
    func testLateResponseAfterSignoutCannotPublishPrivateData() async throws {
        let server = try HouseholdTestServer(), model = await joined(server)
        await server.holdNext()
        let refresh = Task { await model.refresh() }
        await server.waitHeld()
        model.signOut(); await server.release(); await refresh.value
        XCTAssertNil(model.session); XCTAssertNil(model.preferences); XCTAssertTrue(model.active)
        XCTAssertNil(model.selected)
    }
    func testAuthenticatedIdentityChangeCannotReuseStoredDraftNamespace() async throws {
        let server = try HouseholdTestServer(), model = await joined(server)
        let identity = try XCTUnwrap(model.selected?.identity)
        try await server.useOwner(); await model.refresh()
        XCTAssertNil(model.session); XCTAssertNil(model.preferences)
        XCTAssertEqual(model.selected?.identity?.identity, identity.identity)
    }
    func testOwnerReturnRequiresAuthenticationAndInactiveWorkspaceCannotSend() async throws {
        let server = try HouseholdTestServer(), model = await joined(server)
        await model.returnToOwner(authenticate: { false }); XCTAssertTrue(model.active)
        await model.returnToOwner(authenticate: { true }); XCTAssertFalse(model.active)
        let before = await server.calls.count
        await model.refresh(); await model.retryPending()
        await model.start(address: endpoint.absoluteString, name: "x", deviceName: "x", invitation: invitation)
        let after = await server.calls.count; XCTAssertEqual(before, after)
    }
}

@MainActor private final class HouseholdTestVault: HouseholdVault {
    var state = HouseholdVaultState(), reject = false
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { if reject { throw HouseholdFailure.storage }; self.state = state }
}

private actor HouseholdTestServer: HouseholdTransport {
    struct Call: Sendable { let path: String; let method: String; let token: String?; let body: Data? }
    var calls: [Call] = []
    private var values: [String: Data]
    private var failure: HouseholdFailure?
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    init() throws { values = try Self.fixture(); values["session"] = values["memberSession"] }
    static func fixture() throws -> [String: Data] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "household-preparation-v1", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try object.mapValues { try JSONSerialization.data(withJSONObject: $0) }
    }
    func failNext(_ value: HouseholdFailure) { failure = value }
    func holdNext() { hold = true }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func useOwner() throws {
        values["session"] = values["ownerSession"]
        let session = try JSONDecoder().decode(HouseholdSession.self, from: XCTUnwrap(values["session"]))
        for key in ["preferences", "routines"] {
            var data = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(values[key])) as? [String: Any])
            data["sleeperId"] = session.selfSleeperId
            values[key] = try JSONSerialization.data(withJSONObject: data)
        }
    }
    func addOtherDevice() throws {
        let device = HouseholdDevice(id: UUID().uuidString, name: "Other device", createdAt: "2026-10-29T22:00:00Z", current: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(values["devices"])) as? [String: Any])
        var devices = try XCTUnwrap(object["devices"] as? [[String: Any]])
        devices.append(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any]))
        object["devices"] = devices; values["devices"] = try JSONSerialization.data(withJSONObject: object)
    }
    func changePreferencesRevision(_ revision: Int) throws {
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(values["preferences"])) as? [String: Any])
        data["revision"] = revision; values["preferences"] = try JSONSerialization.data(withJSONObject: data)
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        calls.append(.init(path: path, method: method, token: token, body: body))
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        if let failure { self.failure = nil; throw failure }
        let key = path.split(separator: "/").last.map(String.init) ?? ""
        if ["setup", "join", "session"].contains(key) { return try XCTUnwrap(values["session"]) }
        if method == "DELETE" { return try XCTUnwrap(values["revoked"]) }
        if method == "PUT" {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
            var result = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(values[key])) as? [String: Any])
            result[key] = payload[key]; result["revision"] = (payload["expectedRevision"] as? Int ?? 0) + 1
            values[key] = try JSONSerialization.data(withJSONObject: result)
        }
        if method == "POST" && key == "invitations" {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
            return try JSONSerialization.data(withJSONObject: ["id": payload["requestId"]!, "kind": payload["kind"]!, "invitation": payload["invitation"]!, "expiresAt": "2026-12-01T00:00:00Z"])
        }
        return try XCTUnwrap(values[key])
    }
}
