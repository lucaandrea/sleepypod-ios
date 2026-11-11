import Foundation
import FreeSleepKit

/// Profiles are encrypted and tied to both the owner credential revision and account boundary.
@MainActor final class OwnerRouteProfileStore {
    private let store: PrivateSnapshotStore
    private let ownerAllowed: () -> Bool
    private let defaults: UserDefaults

    init(store: PrivateSnapshotStore = .init(namespace: "verified-owner-routes-v1"),
         defaults: UserDefaults = .standard,
         ownerAllowed: @escaping () -> Bool = { !PersonalWorkspaceBoundary.isActive }) {
        self.store = store; self.defaults = defaults; self.ownerAllowed = ownerAllowed
    }

    func load(revision: [String], key: (String) -> String) throws -> EnrolledOwnerRoutes? {
        let scope = try scope(revision)
        guard let profile = try store.read(EnrolledOwnerRoutes.self, scope: scope) else {
            // Losing a previously enrolled profile must not silently create a new data/alarm identity.
            guard !defaults.bool(forKey: expectationKey(scope)) else { throw ControllerIdentityFailure.invalidProfile }
            return nil
        }
        try validate(profile, revision: revision, key: key)
        return profile
    }

    func save(_ profile: EnrolledOwnerRoutes, revision: [String], key: (String) -> String) throws {
        let scope = try scope(revision)
        try validate(profile, revision: revision, key: key)
        try store.write(profile, scope: scope)
        defaults.set(true, forKey: expectationKey(scope))
    }

    /// Disabling selection retains the identity anchor; it must not silently orphan history or alarms.
    func setEnabled(_ enabled: Bool, revision: [String], key: (String) -> String) throws -> EnrolledOwnerRoutes {
        guard var profile = try load(revision: revision, key: key) else { throw ControllerIdentityFailure.invalidProfile }
        profile.routes.enabled = enabled
        try save(profile, revision: revision, key: key)
        return profile
    }

    private func scope(_ revision: [String]) throws -> String {
        guard ownerAllowed(), revision.count == 5, revision[0] == APIBackend.sleepypodCore.rawValue,
              !revision[3].isEmpty else { throw ControllerIdentityFailure.changedCredentials }
        return revision[3]
    }

    private func expectationKey(_ revision: String) -> String { "ownerRoutes.expected.\(revision)" }

    private func validate(_ profile: EnrolledOwnerRoutes, revision: [String], key: (String) -> String) throws {
        try profile.validateContext(revision)
        _ = try profile.routes.candidates(currentAddress: revision[1], revision: revision[3], key: key)
        guard ownerAllowed() else { throw ControllerIdentityFailure.changedCredentials }
    }
}
