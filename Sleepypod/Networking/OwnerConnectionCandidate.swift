import Foundation
import FreeSleepKit

/// A user-entered destination is checked without changing the active controller or its key.
struct OwnerConnectionCandidate: Sendable {
    let endpoint: URL
    let streamAddress: String
    let backend: APIBackend
    let token: String

    init(address: String, streamAddress: String, backend: APIBackend, token: String) throws {
        guard backend != .demo else { throw APIError.notSupported("Choose a real controller to connect.") }
        endpoint = try UnifiedRuntime.validatedEndpoint(address)
        self.backend = backend
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.token.isEmpty || (self.token.count >= 32 && self.token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })) else {
            throw APIError.notSupported("Enter the complete connection key without spaces or line breaks, or leave it blank to keep the key saved for this address.")
        }
        let stream = streamAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stream.isEmpty {
            guard let parts = URLComponents(string: stream), let url = parts.url,
                  url.host?.lowercased() == endpoint.host?.lowercased(), parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  parts.scheme == (endpoint.scheme == "https" ? "wss" : "ws") else {
                throw APIError.notSupported("Use the controller’s same host and matching secure transport for its sensor stream.")
            }
        }
        self.streamAddress = stream
    }

    /// Candidate credentials can authorize only this read, never a discovered host or a mutation.
    func authorizeStatusCheck(_ request: URLRequest) throws -> URLRequest {
        let path = backend == .sleepypodCore ? "/api/trpc/device.getStatus" : "/api/deviceStatus"
        guard let url = request.url, request.httpMethod == "GET", url.path == path,
              url.scheme == endpoint.scheme, url.host == endpoint.host, url.port == endpoint.port,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw APIError.notSupported("Connection checks can only read the selected controller’s status.")
        }
        var checked = request
        checked.setValue(token.isEmpty ? nil : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        checked.cachePolicy = .reloadIgnoringLocalCacheData
        return checked
    }

    func check(session: URLSession = OwnerConnection.session) async throws {
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        switch backend {
        case .sleepypodCore:
            _ = try await SleepypodCoreClient(session: session, baseURL: endpoint, connectionCheck: self).getDeviceStatus()
        case .freeSleep:
            _ = try await FreeSleepClient(session: session, baseURL: endpoint, connectionCheck: self).getDeviceStatus()
        case .demo:
            throw APIError.notSupported("Demo is not a live controller.")
        }
    }
}
