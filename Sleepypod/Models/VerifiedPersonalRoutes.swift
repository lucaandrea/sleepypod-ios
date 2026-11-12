import CryptoKit
import Foundation

/// Stored with the personal device key. A verified pair preserves the original private-cache namespace.
struct VerifiedPersonalRoutes: Codable, Equatable, Sendable {
    let version: Int
    let connectionID: UUID
    let identity: [String]
    let credentialDigest: String
    let home: URL
    let away: URL
    let cacheOrigin: URL
    let verifiedAt: Date
    var enabled: Bool

    init(record: HouseholdConnectionRecord, home: URL, away: URL, now: Date) throws {
        guard let session = record.identity else { throw HouseholdFailure.changedIdentity }
        version = 1; connectionID = record.id; identity = session.identity
        credentialDigest = Self.digest(record.deviceSecret)
        self.home = home; self.away = away; verifiedAt = now; enabled = true
        if let previous = record.verifiedRoutes {
            try previous.validate(id: record.id, endpoint: record.endpoint, token: record.deviceSecret, session: session)
            cacheOrigin = previous.cacheOrigin
        } else { cacheOrigin = record.endpoint }
        try validate(id: record.id, endpoint: record.endpoint, token: record.deviceSecret, session: session)
    }

    func validate(id: UUID, endpoint: URL, token: String, session: HouseholdSession) throws {
        try session.validate()
        guard version == 1, id == connectionID, identity == session.identity,
              HouseholdValidation.secret(token), credentialDigest == Self.digest(token),
              home != away, away.scheme == "https", [home, away].contains(endpoint), [home, away].contains(cacheOrigin),
              verifiedAt.timeIntervalSince1970.isFinite, verifiedAt.timeIntervalSince1970 > 0 else {
            throw HouseholdFailure.changedIdentity
        }
        for origin in [home, away, cacheOrigin] {
            guard try HouseholdHTTPClient.endpoint(origin.absoluteString) == origin else { throw HouseholdFailure.invalid }
        }
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension HouseholdConnectionRecord {
    func connection(for session: HouseholdSession) -> PersonalBedConnection {
        .init(id: id, endpoint: endpoint, token: deviceSecret, session: session, verifiedRoutes: verifiedRoutes)
    }
}
