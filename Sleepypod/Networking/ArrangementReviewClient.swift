import Foundation

protocol ArrangementReviewTransport: Sendable {
    func session() async throws -> HouseholdSession
    func latest() async throws -> ArrangementIndex
    func review(_ id: UUID) async throws -> ArrangementReview
    func send(_ action: ArrangementRequest.Action, body: Data) async throws -> ArrangementReview
}

/// Personal credentials, fixed routes and ephemeral transport keep review data out of owner APIs and caches.
struct ArrangementReviewHTTPClient: ArrangementReviewTransport {
    let connection: PersonalBedConnection
    var transport: URLSession = Self.transport
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ArrangementRedirectPolicy(), delegateQueue: nil)
    }()
    func session() async throws -> HouseholdSession {
        try JSONDecoder().decode(HouseholdSession.self, from: await read("household/session"))
    }
    func latest() async throws -> ArrangementIndex { try ArrangementIndex.decodeExact(await read("household/arrangement")) }
    func review(_ id: UUID) async throws -> ArrangementReview {
        try ArrangementReview.decodeExact(await read("household/arrangement/\(id.uuidString.lowercased())"))
    }
    func send(_ action: ArrangementRequest.Action, body: Data) async throws -> ArrangementReview {
        _ = try ArrangementRequest.decodeExact(body, action: action, session: connection.session)
        guard action == .cancel || connection.session.capabilities.arrangementReview == true else { throw HouseholdFailure.unavailable }
        let path = "household/arrangement" + (action == .propose ? "" : "/\(action.rawValue)")
        return try ArrangementReview.decodeExact(await read(path, body: body))
    }
    private func read(_ path: String, body: Data? = nil) async throws -> Data {
        guard try HouseholdHTTPClient.endpoint(connection.endpoint.absoluteString) == connection.endpoint,
              HouseholdValidation.secret(connection.token) else { throw HouseholdFailure.authentication }
        let url = connection.endpoint.appending(path: "api/v1").appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body; request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(connection.session.selfSleeperId, forHTTPHeaderField: "X-Sleepypod-Sleeper-Id")
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw HouseholdFailure.uncertain }
        guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 524_288 else { throw HouseholdFailure.invalid }
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw HouseholdFailure.authentication
        case 403: throw HouseholdFailure.forbidden
        case 409: throw HouseholdFailure.conflict
        case 404, 503: throw HouseholdFailure.unavailable
        case 429: throw HouseholdFailure.rateLimited
        default: throw HouseholdFailure.uncertain
        }
    }
}

private final class ArrangementRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
