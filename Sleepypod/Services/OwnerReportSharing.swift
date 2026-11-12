import Foundation
import FreeSleepKit
import UIKit

/// Verify installation identity before sharing, and retire the connection after any credential/account change.
@MainActor enum OwnerReportSharing {
    static func connect() async throws -> MorningReportConnection {
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        guard APIBackend.current == .sleepypodCore, UIApplication.shared.isProtectedDataAvailable,
              let endpoint = OwnerConnection.endpoint, let identity = OwnerDataIdentity.current.revision else {
            throw MorningReportSharingFailure.unavailable
        }
        let revision = OwnerConnection.revision, token = UnifiedRuntime.savedKey(for: endpoint.absoluteString)
        let candidate = try OwnerConnectionCandidate(address: endpoint.absoluteString, streamAddress: "", backend: .sleepypodCore, token: token)
        let installation = try await ControllerIdentityClient().read(candidate)
        let current: @MainActor () -> Bool = {
            !PersonalWorkspaceBoundary.isActive && UIApplication.shared.isProtectedDataAvailable
                && OwnerConnection.revision == revision && OwnerDataIdentity.current.revision == identity
                && UnifiedRuntime.savedKey(for: endpoint.absoluteString) == token
        }
        guard current() else { throw MorningReportSharingFailure.changedAccount }
        if !revision[3].isEmpty, let profile = try OwnerRouteProfileStore().load(revision: revision, key: UnifiedRuntime.savedKey),
           profile.routes.installationID != installation { throw MorningReportSharingFailure.changedAccount }
        let client = try MorningReportHTTPClient(endpoint: candidate.endpoint, token: token, scope: .owner(installationID: installation))
        return .init(address: candidate.endpoint.absoluteString, transport: client, isCurrent: current)
    }
}
