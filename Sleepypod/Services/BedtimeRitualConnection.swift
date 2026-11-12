import CryptoKit
import Foundation
import FreeSleepKit
import UIKit

/// Bind audio history and handoffs to one live account. This factory never opens media itself.
@MainActor enum BedtimeRitualConnection {
    static func owner() async throws -> BedtimeRitualSession {
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        guard APIBackend.current == .sleepypodCore, let endpoint = OwnerConnection.endpoint,
              UIApplication.shared.isProtectedDataAvailable, let identity = OwnerDataIdentity.current.revision else {
            throw BedtimeRitualFailure.connectionRequired
        }
        let revision = OwnerConnection.revision, token = UnifiedRuntime.savedKey(for: endpoint.absoluteString)
        let candidate = try OwnerConnectionCandidate(address: endpoint.absoluteString, streamAddress: "", backend: .sleepypodCore, token: token)
        let installation = try await ControllerIdentityClient().read(candidate)
        let current: @MainActor () -> Bool = {
            !PersonalWorkspaceBoundary.isActive && UIApplication.shared.isProtectedDataAvailable
                && OwnerConnection.revision == revision && OwnerDataIdentity.current.revision == identity
                && UnifiedRuntime.savedKey(for: endpoint.absoluteString) == token
        }
        guard current() else { throw BedtimeRitualFailure.accountChanged }
        if !revision[3].isEmpty, let profile = try OwnerRouteProfileStore().load(revision: revision, key: UnifiedRuntime.savedKey),
           profile.routes.installationID != installation { throw BedtimeRitualFailure.accountChanged }
        let scope = try namespace(["owner", installation.uuidString] + identity)
        return make(client: .init(endpoint: candidate.endpoint, token: token, scope: scope, account: .owner(installation)), current: current)
    }
    static func personal(_ connection: PersonalBedConnection, current: @escaping @MainActor () -> Bool) throws -> BedtimeRitualSession {
        try connection.session.validate()
        guard current() else { throw BedtimeRitualFailure.accountChanged }
        guard connection.session.capabilities.householdQuiet == true else { throw BedtimeRitualFailure.quietUnavailable }
        let scope = try namespace(["personal", connection.id.uuidString] + connection.session.identity)
        return make(client: .init(endpoint: connection.endpoint, token: connection.token, scope: scope, account: .personal(connection.session)), current: current)
    }
    static func namespace(_ identity: [String]) throws -> String {
        SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
    }
    static func removePersonalData(record: HouseholdConnectionRecord) throws {
        guard let identity = record.identity else { return }
        let scope = try namespace(["personal", record.id.uuidString] + identity.identity)
        try BedtimeRitualVault().remove(scope: scope)
    }
    private static func make(client: BedtimeRitualQuietClient, current: @escaping @MainActor () -> Bool) -> BedtimeRitualSession {
        let session = BedtimeRitualSession(scope: client.scope, storage: BedtimeRitualVault(), current: current,
            foreground: { UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable },
            quiet: { try await client.read() }, open: { await UIApplication.shared.open($0) })
        session.restore()
        return session
    }
}
