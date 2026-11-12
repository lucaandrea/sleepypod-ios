import Foundation
import Observation

/// Reads only explicitly enrolled origins. Authentication or identity failures never trigger fallback.
@MainActor @Observable final class OwnerRouteResolver {
    private(set) var checking = false
    private(set) var lastVerifiedAddress: String?
    private(set) var message: String?
    private var generation = UUID()

    func invalidate() {
        generation = UUID(); checking = false; lastVerifiedAddress = nil; message = nil
    }

    func resolve(profile: VerifiedOwnerRoutes, currentAddress: String,
                 candidates: (home: OwnerConnectionCandidate, away: OwnerConnectionCandidate),
                 readIdentity: (OwnerConnectionCandidate) async throws -> UUID,
                 isCurrent: () -> Bool, activate: (OwnerConnectionCandidate) throws -> Void) async -> Bool {
        guard profile.enabled, !checking, isCurrent(),
              [profile.home.address, profile.away.address].contains(currentAddress),
              VerifiedOwnerRoutes.Route(candidates.home) == profile.home,
              VerifiedOwnerRoutes.Route(candidates.away) == profile.away else { return false }
        let operation = UUID()
        generation = operation; checking = true; message = nil; lastVerifiedAddress = nil
        defer { if operation == generation { checking = false } }
        let ordered = currentAddress == profile.home.address
            ? [candidates.home, candidates.away] : [candidates.away, candidates.home]
        for (index, candidate) in ordered.enumerated() {
            do {
                try Task.checkCancellation()
                let identity = try await readIdentity(candidate)
                try Task.checkCancellation()
                guard operation == generation, isCurrent() else { return false }
                guard identity == profile.installationID else { throw ControllerIdentityFailure.differentSavedInstallation }
                // The callback only switches local transport; it must never retry a bed command.
                if candidate.endpoint.absoluteString != currentAddress {
                    do { try activate(candidate) }
                    catch {
                        message = "The controller replied, but this device could not switch the saved connection. No bed action was retried."
                        return false
                    }
                }
                lastVerifiedAddress = candidate.endpoint.absoluteString
                message = candidate.endpoint.absoluteString == profile.home.address
                    ? "Home connection verified." : "Away connection verified."
                return true
            } catch {
                guard operation == generation, isCurrent(), !Task.isCancelled else { return false }
                if index == 0, Self.permitsFallback(after: error) { continue }
                message = Self.failureMessage(error)
                return false
            }
        }
        return false
    }

    static func permitsFallback(after error: Error) -> Bool {
        if case APIError.networkError(let underlying) = error { return permitsFallback(after: underlying) }
        guard let error = error as? URLError else { return false }
        return switch error.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet: true
        default: false
        }
    }

    private static func failureMessage(_ error: Error) -> String {
        if let identity = error as? ControllerIdentityFailure { return identity.localizedDescription }
        if let transport = error as? URLError,
           [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired].contains(transport.code) {
            return "The connection’s secure certificate could not be verified. Review its HTTPS setup before trying another address."
        }
        if ConnectionIssue(error) == .authentication {
            return "This connection no longer authorizes your key. Verify its access before using an alternate address."
        }
        return "The verified connection could not be reached or checked. No bed action was retried. Review the saved addresses and access."
    }
}
