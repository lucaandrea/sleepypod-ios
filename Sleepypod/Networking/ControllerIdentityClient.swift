import Foundation
import FreeSleepKit
import Security

/// Proves a fresh authenticated reply from an explicitly entered origin, not hardware identity.
struct ControllerIdentityClient: Sendable {
    let session: URLSession

    init(session: URLSession = OwnerConnection.session) { self.session = session }

    func read(_ candidate: OwnerConnectionCandidate) async throws -> UUID {
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        try Task.checkCancellation()
        guard candidate.backend == .sleepypodCore, !candidate.token.isEmpty else {
            throw APIError.notSupported("Automatic connections need an authenticated Sleepypod Core controller.")
        }
        let challenge = try Self.challenge()
        guard var components = URLComponents(url: candidate.endpoint.appending(path: "api/v1/connection"), resolvingAgainstBaseURL: false) else {
            throw ControllerIdentityFailure.invalidProfile
        }
        components.queryItems = [.init(name: "challenge", value: challenge)]
        guard let address = components.url else { throw ControllerIdentityFailure.invalidProfile }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(candidate.token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ControllerIdentityFailure.invalidReply }
        guard response.statusCode == 200 else { throw APIError.invalidResponse(statusCode: response.statusCode) }
        guard response.url == address, response.mimeType == "application/json",
              response.expectedContentLength <= 8192 else { throw ControllerIdentityFailure.invalidReply }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8192 else { throw ControllerIdentityFailure.invalidReply }
            data.append(byte)
        }
        try Task.checkCancellation()
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.schemaVersion == 1,
              reply.controller == "sleepypod-core", reply.challenge == challenge,
              let identifier = UUID(uuidString: reply.installationId) else { throw ControllerIdentityFailure.invalidReply }
        return identifier
    }

    private static func challenge() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ControllerIdentityFailure.unavailable
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private struct Reply: Decodable {
        let schemaVersion: Int
        let controller: String
        let installationId: String
        let challenge: String
    }
}
