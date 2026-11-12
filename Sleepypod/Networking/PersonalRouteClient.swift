import Foundation

/// This transport only reads a fresh personal session. It never follows redirects or submits controls.
struct PersonalRouteClient: Sendable {
    var transport: URLSession = Self.transport
    private static let transport = URLSession(configuration: .ephemeral, delegate: PersonalRouteRedirectPolicy(), delegateQueue: nil)

    func read(endpoint: URL, token: String) async throws -> HouseholdSession {
        guard try HouseholdHTTPClient.endpoint(endpoint.absoluteString) == endpoint,
              HouseholdValidation.secret(token) else { throw HouseholdFailure.invalid }
        let challenge = try HouseholdKeychainVault.secret()
        var components = URLComponents(url: endpoint.appending(path: "api/v1/household/session"), resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "challenge", value: challenge)]
        guard let address = components?.url else { throw HouseholdFailure.invalid }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await transport.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == address else { throw HouseholdFailure.invalid }
        switch response.statusCode {
        case 200: break
        case 401: throw HouseholdFailure.authentication
        case 403: throw HouseholdFailure.forbidden
        case 404, 503: throw HouseholdFailure.unavailable
        case 429: throw HouseholdFailure.rateLimited
        default: throw HouseholdFailure.invalid
        }
        guard response.value(forHTTPHeaderField: "X-Sleepypod-Connection-Challenge") == challenge,
              response.mimeType == "application/json", response.expectedContentLength <= 16_384 else {
            throw PersonalRouteFailure.freshness
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { throw HouseholdFailure.invalid }
            data.append(byte)
        }
        try Task.checkCancellation()
        let session = try JSONDecoder().decode(HouseholdSession.self, from: data)
        try session.validate()
        return session
    }
}

private final class PersonalRouteRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum PersonalRouteFailure: Error, LocalizedError {
    case freshness
    var errorDescription: String? { "This controller did not confirm a fresh personal connection. Update Core before enabling automatic connections." }
}
