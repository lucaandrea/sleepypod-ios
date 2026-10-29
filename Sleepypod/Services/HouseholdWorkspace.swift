import Foundation
import FreeSleepKit
import LocalAuthentication
import Observation

@MainActor @Observable final class HouseholdWorkspace {
    private(set) var active: Bool
    private(set) var session: HouseholdSession?
    private(set) var preferences: HouseholdPreferencesResponse?
    private(set) var routines: HouseholdRoutinesResponse?
    private(set) var devices: [HouseholdDevice] = []
    private(set) var invitations: [HouseholdInvitation] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var state = HouseholdVaultState()
    private let vault: any HouseholdVault
    private let defaults: UserDefaults
    private let client: @Sendable (URL) -> any HouseholdTransport
    private let capability: @MainActor () async throws -> Bool
    private var ownerGateScope: [String]?
    private let ownerEndpoint: @MainActor () -> URL?
    private let ownerKey: @MainActor (URL) -> String
    private let secret: @MainActor () throws -> String
    private var generation = 0
    private var storageLoaded = false

    init(vault: any HouseholdVault = HouseholdKeychainVault(), defaults: UserDefaults = .standard,
         client: @escaping @Sendable (URL) -> any HouseholdTransport = { HouseholdHTTPClient(endpoint: $0) },
         capability: @escaping @MainActor () async throws -> Bool = { try await HouseholdPreparationCapability.load() },
         ownerEndpoint: @escaping @MainActor () -> URL? = { OwnerConnection.endpoint },
         ownerKey: @escaping @MainActor (URL) -> String = { UnifiedRuntime.savedKey(for: $0.absoluteString) },
         secret: @escaping @MainActor () throws -> String = { try HouseholdKeychainVault.secret() }) {
        self.vault = vault; self.defaults = defaults; self.client = client; self.capability = capability; self.ownerEndpoint = ownerEndpoint; self.ownerKey = ownerKey; self.secret = secret
        active = defaults.bool(forKey: PersonalWorkspaceBoundary.preferenceKey)
        do { state = try vault.load(); storageLoaded = true } catch { self.error = HouseholdFailure.storage.localizedDescription }
    }
    var selected: HouseholdConnectionRecord? { state.connections.first { $0.id == state.selected } }
    var pending: HouseholdPendingRequest? { selected?.pending }
    var needsDraftReview: Bool {
        (selected?.draftPreferencesRevision != nil && selected?.draftPreferencesRevision != preferences?.revision)
            || (selected?.draftRoutinesRevision != nil && selected?.draftRoutinesRevision != routines?.revision)
    }
    var maySave: Bool { active && session != nil && !busy && pending == nil && preferences != nil && routines != nil && !needsDraftReview }
    func reviewDrafts(keep: Bool) {
        guard pending == nil, let record = selected, let preferences, let routines else { return }
        do {
            try update(record.id) {
                if keep {
                    if $0.draftPreferences != nil { $0.draftPreferencesRevision = preferences.revision }
                    if $0.draftRoutines != nil { $0.draftRoutinesRevision = routines.revision }
                } else {
                    $0.draftPreferences = nil; $0.draftRoutines = nil
                    $0.draftPreferencesRevision = nil; $0.draftRoutinesRevision = nil
                }
            }
        } catch { self.error = HouseholdFailure.storage.localizedDescription }
    }
    var savedConnections: [HouseholdConnectionRecord] { state.connections }
    var ownerSetupReady: Bool { ownerGateScope != nil && ownerGateScope == Array(OwnerConnection.revision.prefix(4)) }
    func checkOwnerPreparation() async {
        let context = Array(OwnerConnection.revision.prefix(4))
        ownerGateScope = nil
        if (try? await capability()) == true, context == Array(OwnerConnection.revision.prefix(4)) { ownerGateScope = context }
    }
    var canReturnToOwner: Bool { ownerEndpoint().map { !ownerKey($0).isEmpty } == true }
    var draftPreferences: HouseholdPreferences { selected?.draftPreferences ?? preferences?.preferences ?? .blank }
    var draftRoutines: [HouseholdRoutine] { selected?.draftRoutines ?? routines?.routines ?? [] }

    func enter() {
        generation += 1; active = true
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        defaults.set(UUID().uuidString, forKey: "household.boundaryRevision")
        UnifiedRuntime.suspendPersonalBackgroundWork()
        OwnerConnection.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        clearVisible()
        if !storageLoaded {
            do { state = try vault.load(); storageLoaded = true } catch { self.error = HouseholdFailure.storage.localizedDescription }
        }
    }
    /// Returning to a retained installation-owner key requires the device owner's authentication.
    func returnToOwner(authenticate: (() async throws -> Bool)? = nil) async {
        guard !busy, canReturnToOwner else { return }
        do {
            let accepted: Bool
            if let authenticate { accepted = try await authenticate() }
            else { accepted = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Return to this iPhone’s existing Pod owner connection") }
            guard accepted else { return }
            generation += 1; clearVisible(); active = false
            defaults.set(UUID().uuidString, forKey: "household.boundaryRevision")
            defaults.set(false, forKey: PersonalWorkspaceBoundary.preferenceKey)
        } catch { self.error = "Owner authentication was not completed. Personal preparation remains open." }
    }
    func signOut() {
        generation += 1; clearVisible()
        do { var next = state; next.selected = nil; try persist(next) } catch { self.error = error.localizedDescription }
    }
    func select(_ id: UUID) async {
        guard active, !busy, state.connections.contains(where: { $0.id == id }) else { return }
        generation += 1; clearVisible()
        do { var next = state; next.selected = id; try persist(next); await refresh() } catch { self.error = error.localizedDescription }
    }

    func start(address: String, name: String, deviceName: String, invitation: String?, sourceSide: Side = .left) async {
        guard active, !busy, pending == nil, storageLoaded else { return }
        do {
            let endpoint = try HouseholdHTTPClient.endpoint(address)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines), deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard HouseholdValidation.name(name), HouseholdValidation.name(deviceName) else { throw HouseholdFailure.invalid }
            let deviceSecret = try secret()
            guard HouseholdValidation.secret(deviceSecret) else { throw HouseholdFailure.storage }
            let request: HouseholdPendingRequest
            if let invitation {
                guard HouseholdValidation.secret(invitation) else { throw HouseholdFailure.invitation }
                request = .init(kind: .join, body: try HouseholdRequestBody.data([
                    "invitation": invitation, "deviceSecret": deviceSecret, "deviceName": deviceName, "displayName": name
                ]))
            } else {
                guard ownerSetupReady, endpoint == ownerEndpoint(), !ownerKey(endpoint).isEmpty else { throw HouseholdFailure.forbidden }
                request = .init(kind: .setup, body: try HouseholdRequestBody.data([
                    "requestId": UUID().uuidString, "displayName": name, "deviceName": deviceName, "deviceSecret": deviceSecret,
                    "currentMode": "solo-anywhere", "sourceSide": sourceSide.rawValue, "acknowledgeExistingOwner": true
                ]))
            }
            // Store the generated key and exact request before the first network effect.
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: endpoint, deviceSecret: deviceSecret, pending: request)
            var next = state; next.connections.append(record); next.selected = record.id
            try persist(next); generation += 1; clearVisible()
            await retryPending()
        } catch { self.error = (error as? HouseholdFailure ?? .invalid).localizedDescription }
    }

    func refresh() async {
        guard active, !busy else { return }
        if !storageLoaded {
            do { state = try vault.load(); storageLoaded = true }
            catch { self.error = HouseholdFailure.storage.localizedDescription; return }
        }
        guard let record = selected else { return }
        let operation = generation; busy = true; error = nil
        defer { if operation == generation { busy = false } }
        do {
            let value: HouseholdSession = try await read("household/session", record: record)
            try value.validate(); try check(operation, record.id)
            if let previous = record.identity, previous.identity != value.identity { throw HouseholdFailure.changedIdentity }
            session = value
            try update(record.id) { saved in
                saved.identity = value
                if saved.pending?.kind == .setup || saved.pending?.kind == .join { saved.pending = nil }
            }
            let personal: HouseholdPreferencesResponse = try await read("me/preferences", record: record)
            try personal.validate(for: value); try check(operation, record.id)
            let week: HouseholdRoutinesResponse = try await read("me/routines", record: record)
            try week.validate(for: value); try check(operation, record.id)
            struct Devices: Decodable { let devices: [HouseholdDevice] }
            struct Invitations: Decodable { let invitations: [HouseholdInvitation] }
            let paired: Devices = try await read("household/devices", record: record)
            try paired.devices.forEach { try $0.validate() }
            guard Set(paired.devices.map(\.id)).count == paired.devices.count, paired.devices.filter(\.current).count == 1 else { throw HouseholdFailure.invalid }
            let invited: Invitations = try await read("household/invitations", record: record)
            try invited.invitations.forEach { try $0.validate() }; try check(operation, record.id)
            guard Set(invited.invitations.map(\.id)).count == invited.invitations.count else { throw HouseholdFailure.invalid }
            preferences = personal; routines = week; devices = paired.devices; invitations = invited.invitations
            notice = pending == nil ? "Personal account refreshed. Routine drafts do not run the bed." : "Saved state refreshed. An earlier request still needs review; retrying uses the same request."
        } catch {
            guard operation == generation else { return }
            clearVisible()
            if error as? HouseholdFailure == .authentication, record.identity != nil { try? forget(record.id) }
            self.error = (error as? HouseholdFailure ?? .invalid).localizedDescription
        }
    }

    func savePreferences(_ value: HouseholdPreferences) async {
        guard maySave, let session, let preferences, let record = selected else { return }
        do {
            try value.validate()
            var body = HouseholdRequestBody.context(session)
            body["expectedRevision"] = preferences.revision; body["preferences"] = try HouseholdRequestBody.object(value)
            try update(record.id) { $0.draftPreferences = value; $0.draftPreferencesRevision = preferences.revision }
            try prepare(.init(kind: .preferences, body: HouseholdRequestBody.data(body)))
            await retryPending()
        } catch { self.error = error.localizedDescription }
    }
    func saveRoutines(_ value: [HouseholdRoutine]) async {
        guard maySave, let session, let routines, let record = selected else { return }
        do {
            try HouseholdRoutine.validate(value)
            var body = HouseholdRequestBody.context(session)
            body["expectedRevision"] = routines.revision; body["routines"] = try HouseholdRequestBody.object(value)
            try update(record.id) { $0.draftRoutines = value; $0.draftRoutinesRevision = routines.revision }
            try prepare(.init(kind: .routines, body: HouseholdRequestBody.data(body)))
            await retryPending()
        } catch { self.error = error.localizedDescription }
    }
    func invite(kind: String, minutes: Int = 60) async {
        guard maySave, let session, ["new_person", "own_device"].contains(kind),
              kind != "new_person" || session.capabilities.manageInvitations else { return }
        do {
            var body = HouseholdRequestBody.context(session)
            body["kind"] = kind; body["invitation"] = try secret(); body["expiresInMinutes"] = minutes
            try prepare(.init(kind: .invitation, body: HouseholdRequestBody.data(body))); await retryPending()
        } catch { self.error = error.localizedDescription }
    }
    func revoke(invitationId: String? = nil, deviceId: String? = nil) async {
        guard maySave, let session, (invitationId == nil) != (deviceId == nil) else { return }
        do {
            if let deviceId {
                guard devices.count > 1, devices.contains(where: { $0.id == deviceId }) else { throw HouseholdFailure.forbidden }
            }
            if let invitationId {
                guard invitations.contains(where: { $0.id == invitationId && $0.status == "pending" }) else { throw HouseholdFailure.invitation }
            }
            var body = HouseholdRequestBody.context(session)
            body[invitationId == nil ? "deviceId" : "invitationId"] = invitationId ?? deviceId
            try prepare(.init(kind: invitationId == nil ? .revokeDevice : .revokeInvitation, body: HouseholdRequestBody.data(body)))
            await retryPending()
        } catch { self.error = error.localizedDescription }
    }
    func invitationCode(_ id: String) -> String? {
        guard invitations.contains(where: { $0.id == id && $0.status == "pending" }) else { return nil }
        return selected?.invitationSecrets[id]
    }

    /// A manual retry reuses the durable request and credential; never rotate after an unknown result.
    func retryPending() async {
        guard active, !busy, let record = selected, let pending = record.pending else { return }
        let operation = generation; busy = true; error = nil; notice = nil
        defer { if operation == generation { busy = false } }
        do {
            let token: String? = pending.kind == .join ? nil : pending.kind == .setup ? ownerKey(record.endpoint) : record.deviceSecret
            guard pending.kind != .setup || token?.isEmpty == false else { throw HouseholdFailure.authentication }
            let data = try await client(record.endpoint).send(path: pending.path, method: pending.method, token: token, body: pending.body)
            try check(operation, record.id)
            try accept(data, pending: pending, record: record)
            busy = false
            await refresh()
        } catch {
            guard operation == generation else { return }
            let failure = error as? HouseholdFailure ?? .uncertain
            // Definitive rejections may be reviewed and corrected. Transport/decode uncertainty stays durable.
            if [.conflict, .forbidden, .invitation, .rateLimited, .unavailable].contains(failure) {
                try? update(record.id) { $0.pending = nil }
            }
            if failure == .authentication || failure == .changedIdentity || failure == .conflict { clearVisible() }
            if failure == .authentication, record.identity != nil { try? forget(record.id) }
            self.error = failure.localizedDescription
        }
    }

    private func accept(_ data: Data, pending: HouseholdPendingRequest, record: HouseholdConnectionRecord) throws {
        let decoder = JSONDecoder()
        switch pending.kind {
        case .setup, .join:
            let value = try decoder.decode(HouseholdSession.self, from: data); try value.validate()
            if let previous = record.identity, value.identity != previous.identity { throw HouseholdFailure.changedIdentity }
            try update(record.id) { $0.identity = value; $0.pending = nil }
        case .preferences:
            guard let session else { throw HouseholdFailure.changedIdentity }
            let value = try decoder.decode(HouseholdPreferencesResponse.self, from: data); try value.validate(for: session)
            guard value.preferences == record.draftPreferences else { throw HouseholdFailure.uncertain }
            try update(record.id) { $0.pending = nil; $0.draftPreferences = nil; $0.draftPreferencesRevision = nil }
        case .routines:
            guard let session else { throw HouseholdFailure.changedIdentity }
            let value = try decoder.decode(HouseholdRoutinesResponse.self, from: data); try value.validate(for: session)
            guard value.routines == record.draftRoutines, value.status == "draft_only" else { throw HouseholdFailure.uncertain }
            try update(record.id) { $0.pending = nil; $0.draftRoutines = nil; $0.draftRoutinesRevision = nil }
        case .invitation:
            let value = try decoder.decode(HouseholdInvitationReceipt.self, from: data)
            let original = try JSONSerialization.jsonObject(with: pending.body) as? [String: Any]
            guard value.id == original?["requestId"] as? String, value.invitation == original?["invitation"] as? String,
                  value.kind == original?["kind"] as? String, SensorObservation.date(value.expiresAt) != nil else { throw HouseholdFailure.uncertain }
            try update(record.id) { $0.pending = nil; $0.invitationSecrets[value.id] = value.invitation }
        case .revokeInvitation, .revokeDevice:
            struct Receipt: Decodable { let revoked: Bool }
            guard try decoder.decode(Receipt.self, from: data).revoked else { throw HouseholdFailure.uncertain }
            let original = try JSONSerialization.jsonObject(with: pending.body) as? [String: Any]
            if pending.kind == .revokeDevice, devices.contains(where: { $0.current && $0.id == original?["deviceId"] as? String }) {
                try forget(record.id); clearVisible()
                notice = "This device has been revoked. Personal preparation remains open."
            } else {
                try update(record.id) {
                    $0.pending = nil
                    if let identifier = original?["invitationId"] as? String { $0.invitationSecrets.removeValue(forKey: identifier) }
                }
            }
        }
    }
    private func forget(_ id: UUID) throws {
        var next = state
        next.connections.removeAll { $0.id == id }
        if next.selected == id { next.selected = nil }
        try persist(next)
    }
    private func prepare(_ request: HouseholdPendingRequest) throws {
        guard active, let record = selected, record.pending == nil else { throw HouseholdFailure.uncertain }
        try update(record.id) { $0.pending = request }
    }
    private func read<Value: Decodable>(_ path: String, record: HouseholdConnectionRecord) async throws -> Value {
        let data = try await client(record.endpoint).send(path: path, method: "GET", token: record.deviceSecret, body: nil)
        return try JSONDecoder().decode(Value.self, from: data)
    }
    private func check(_ operation: Int, _ id: UUID) throws {
        guard active, operation == generation, state.selected == id, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
    private func update(_ id: UUID, change: (inout HouseholdConnectionRecord) -> Void) throws {
        var next = state
        guard let index = next.connections.firstIndex(where: { $0.id == id }) else { throw HouseholdFailure.changedIdentity }
        change(&next.connections[index]); try persist(next)
    }
    private func persist(_ next: HouseholdVaultState) throws {
        guard storageLoaded else { throw HouseholdFailure.storage }
        do { try vault.save(next); state = next } catch { throw HouseholdFailure.storage }
    }
    private func clearVisible() {
        session = nil; preferences = nil; routines = nil; devices = []; invitations = []; busy = false; error = nil; notice = nil
    }
}
