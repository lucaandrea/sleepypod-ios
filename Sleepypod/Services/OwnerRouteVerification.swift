import Foundation

/// Both user-entered origins must answer fresh authenticated challenges before they can be alternatives.
@MainActor enum OwnerRouteVerification {
    static func verify(home: OwnerConnectionCandidate, away: OwnerConnectionCandidate,
                       currentAddress: String, credentialRevision: String, now: Date,
                       isCurrent: () -> Bool,
                       readIdentity: (OwnerConnectionCandidate) async throws -> UUID) async throws -> VerifiedOwnerRoutes {
        guard [home.endpoint.absoluteString, away.endpoint.absoluteString].contains(currentAddress), isCurrent() else {
            throw ControllerIdentityFailure.changedCredentials
        }
        // Validate the complete shape before either origin can receive a request.
        _ = try VerifiedOwnerRoutes(installationID: UUID(), credentialRevision: credentialRevision, home: home, away: away, now: now)
        try Task.checkCancellation()
        let homeID = try await read(home, connection: .home, identity: readIdentity)
        try Task.checkCancellation()
        guard isCurrent() else { throw ControllerIdentityFailure.changedCredentials }
        let awayID = try await read(away, connection: .away, identity: readIdentity)
        try Task.checkCancellation()
        guard isCurrent() else { throw ControllerIdentityFailure.changedCredentials }
        guard homeID == awayID else { throw ControllerIdentityFailure.differentInstallation }
        return try VerifiedOwnerRoutes(installationID: homeID, credentialRevision: credentialRevision, home: home, away: away, now: now)
    }

    private static func read(_ candidate: OwnerConnectionCandidate, connection: OwnerRouteCheckFailure.Connection,
                             identity: (OwnerConnectionCandidate) async throws -> UUID) async throws -> UUID {
        do { return try await identity(candidate) }
        catch is CancellationError { throw CancellationError() }
        catch { throw OwnerRouteCheckFailure(connection: connection, error: error) }
    }
}
