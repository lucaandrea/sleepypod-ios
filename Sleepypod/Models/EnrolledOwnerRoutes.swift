import Foundation

/// A logical owner's data identity remains stable across two verified transport origins.
struct EnrolledOwnerRoutes: Codable, Equatable, Sendable {
    let version: Int
    var routes: VerifiedOwnerRoutes
    let originalRevision: [String]

    init(routes: VerifiedOwnerRoutes, currentRevision: [String], previous: EnrolledOwnerRoutes? = nil,
         initialIdentity: [String]? = nil) throws {
        version = 1
        self.routes = routes
        guard Self.valid(currentRevision), currentRevision[3] == routes.credentialRevision,
              [routes.home.address, routes.away.address].contains(currentRevision[1]) else {
            throw ControllerIdentityFailure.invalidProfile
        }
        if let previous {
            try previous.validateContext(currentRevision)
            guard previous.routes.installationID == routes.installationID else { throw ControllerIdentityFailure.differentSavedInstallation }
            originalRevision = previous.originalRevision
        } else if let initialIdentity {
            // Older saved connections lack a revision. Enrollment must retain their existing cache identity.
            guard initialIdentity.count == 5, initialIdentity[3].isEmpty,
                  initialIdentity.enumerated().allSatisfy({ $0.offset == 3 || $0.element == currentRevision[$0.offset] }) else {
                throw ControllerIdentityFailure.changedCredentials
            }
            originalRevision = initialIdentity
        } else { originalRevision = currentRevision }
    }

    func validateContext(_ current: [String]) throws {
        guard version == 1, originalRevision.count == 5, originalRevision[0] == APIBackend.sleepypodCore.rawValue,
              !originalRevision[1].isEmpty, Self.valid(current), current[3] == routes.credentialRevision,
              originalRevision[3].isEmpty || originalRevision[3] == routes.credentialRevision,
              current[4] == originalRevision[4],
              [routes.home.address, routes.away.address].contains(current[1]) else {
            throw ControllerIdentityFailure.changedCredentials
        }
    }

    private static func valid(_ revision: [String]) -> Bool {
        revision.count == 5 && revision[0] == APIBackend.sleepypodCore.rawValue
            && !revision[1].isEmpty && !revision[3].isEmpty
    }
}
