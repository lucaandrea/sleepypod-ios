import CryptoKit
import Foundation
import FreeSleepKit

/// Metadata never contains credentials. Each enrolled origin retains its own Keychain entry.
struct VerifiedOwnerRoutes: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    let installationID: UUID
    let credentialRevision: String
    let verifiedAt: Date
    let home: Route
    let away: Route
    var enabled: Bool

    struct Route: Codable, Equatable, Sendable {
        let address: String
        let streamAddress: String
        let credentialDigest: String

        init(_ candidate: OwnerConnectionCandidate) {
            address = candidate.endpoint.absoluteString
            streamAddress = candidate.streamAddress
            credentialDigest = Self.digest(candidate.token)
        }

        func candidate(key: String) throws -> OwnerConnectionCandidate {
            guard !key.isEmpty, Self.digest(key) == credentialDigest else { throw ControllerIdentityFailure.changedCredentials }
            let candidate = try OwnerConnectionCandidate(address: address, streamAddress: streamAddress, backend: .sleepypodCore, token: key)
            guard candidate.endpoint.absoluteString == address else { throw ControllerIdentityFailure.invalidProfile }
            return candidate
        }

        private static func digest(_ key: String) -> String {
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    init(installationID: UUID, credentialRevision: String, home: OwnerConnectionCandidate, away: OwnerConnectionCandidate, now: Date) throws {
        guard home.backend == .sleepypodCore, away.backend == .sleepypodCore,
              away.endpoint.scheme == "https", home.endpoint != away.endpoint,
              !home.token.isEmpty, !away.token.isEmpty, !credentialRevision.isEmpty,
              now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0 else {
            throw ControllerIdentityFailure.invalidProfile
        }
        schemaVersion = 1; profileID = UUID(); self.installationID = installationID
        self.credentialRevision = credentialRevision; verifiedAt = now
        self.home = Route(home); self.away = Route(away); enabled = true
    }

    func candidates(currentAddress: String, revision: String, key: (String) -> String) throws -> (home: OwnerConnectionCandidate, away: OwnerConnectionCandidate) {
        guard schemaVersion == 1, !credentialRevision.isEmpty, revision == credentialRevision, verifiedAt.timeIntervalSince1970.isFinite,
              verifiedAt.timeIntervalSince1970 > 0, home.address != away.address,
              [home.address, away.address].contains(currentAddress) else { throw ControllerIdentityFailure.invalidProfile }
        let homeCandidate = try home.candidate(key: key(home.address))
        let awayCandidate = try away.candidate(key: key(away.address))
        guard awayCandidate.endpoint.scheme == "https" else { throw ControllerIdentityFailure.invalidProfile }
        return (homeCandidate, awayCandidate)
    }

    var cacheScope: String {
        let value = "verified-owner|\(profileID)|\(installationID)|\(credentialRevision)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
