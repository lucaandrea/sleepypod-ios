import Foundation

/// Fixed personal GET routes never inherit owner credentials, cookies, redirects or response caches.
struct PersonalHistoryHTTPClient: PersonalHistoryTransport {
    let connection: PersonalBedConnection
    var transport: URLSession = Self.transport
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PersonalHistoryRedirectPolicy(), delegateQueue: nil)
    }()
    func session() async throws -> HouseholdSession {
        try JSONDecoder().decode(HouseholdSession.self, from: await read("household/session"))
    }
    func page(_ query: PersonalHistoryQuery, cursor: String?) async throws -> PersonalHistoryPage {
        guard connection.session.capabilities.personalHistory else { throw HouseholdFailure.unavailable }
        try query.validate()
        var parameters = [
            URLQueryItem(name: "startsAt", value: String(query.startsAt)),
            URLQueryItem(name: "endsAt", value: String(query.endsAt)),
            URLQueryItem(name: "kind", value: query.kind.rawValue),
            URLQueryItem(name: "limit", value: String(query.limit))
        ]
        if let cursor {
            guard !cursor.isEmpty, cursor.utf16.count <= 4_096 else { throw HouseholdFailure.invalid }
            parameters.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try PersonalHistoryPage.decodeExact(await read("me/sleep", parameters: parameters))
    }
    func detail(_ id: UUID) async throws -> PersonalHistoryDetail {
        guard connection.session.capabilities.personalHistory else { throw HouseholdFailure.unavailable }
        return try PersonalHistoryDetail.decodeExact(await read("me/sleep/\(id.uuidString.lowercased())"))
    }
    private func read(_ path: String, parameters: [URLQueryItem] = []) async throws -> Data {
        guard try HouseholdHTTPClient.endpoint(connection.endpoint.absoluteString) == connection.endpoint,
              HouseholdValidation.secret(connection.token) else { throw HouseholdFailure.authentication }
        let endpoint = connection.endpoint.appending(path: "api/v1").appending(path: path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw HouseholdFailure.invalid }
        if !parameters.isEmpty {
            components.queryItems = parameters
            // Core uses URLSearchParams, where an unescaped plus becomes a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw HouseholdFailure.invalid }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(connection.session.selfSleeperId, forHTTPHeaderField: "X-Sleepypod-Sleeper-Id")
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw HouseholdFailure.uncertain }
        guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 524_288 else { throw HouseholdFailure.invalid }
        switch response.statusCode {
        case 200: return data
        case 401: throw HouseholdFailure.authentication
        case 403: throw HouseholdFailure.forbidden
        case 409: throw HouseholdFailure.conflict
        case 404, 503: throw HouseholdFailure.unavailable
        case 429: throw HouseholdFailure.rateLimited
        default: throw HouseholdFailure.invalid
        }
    }
}
