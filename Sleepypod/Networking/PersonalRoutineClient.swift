import Foundation

protocol PersonalRoutineTransport: Sendable {
    func session() async throws -> HouseholdSession
    func review() async throws -> PersonalRoutineReview
    func publish(_ body: Data) async throws -> PersonalRoutineReceipt
    func publication(_ requestId: UUID) async throws -> PersonalRoutineReceipt
}

enum PersonalRoutineFailure: Error, LocalizedError {
    case missingReceipt, uncertain, supersededByStop
    var errorDescription: String? {
        switch self {
        case .supersededByStop: "The unsent publication was cancelled by Stop. Review again before publishing. Existing operating routines were not cancelled."
        case .missingReceipt: "No publication receipt is available yet. This does not prove the week was not saved. The request will not be resent."
        case .uncertain: "The publication result could not be confirmed. Check the original receipt and current week; do not publish again to repair it."
        }
    }
    static func message(for error: Error) -> String {
        if error as? HouseholdFailure == .uncertain { return Self.uncertain.localizedDescription }
        return (error as? LocalizedError)?.errorDescription ?? Self.uncertain.localizedDescription
    }
}

/// Publication has its own fixed personal routes and never uses owner-wide schedule endpoints.
struct PersonalRoutineHTTPClient: PersonalRoutineTransport {
    let connection: PersonalBedConnection
    var transport: URLSession = Self.transport
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: PersonalRoutineRedirectPolicy(), delegateQueue: nil)
    }()
    func session() async throws -> HouseholdSession { try await read("household/session") }
    func review() async throws -> PersonalRoutineReview { try await read("me/routines/review") }
    func publication(_ requestId: UUID) async throws -> PersonalRoutineReceipt {
        try await read("me/routines/publications/\(requestId.uuidString.lowercased())", receiptLookup: true)
    }
    func publish(_ body: Data) async throws -> PersonalRoutineReceipt {
        let request = try PersonalRoutineRequest.decodeExact(body)
        guard connection.session.capabilities.personalRoutinePublication == true,
              request.scope.matches(connection.session) else { throw HouseholdFailure.changedIdentity }
        return try await read("me/routines/publish", body: body)
    }
    private func read<Value: Decodable>(_ path: String, body: Data? = nil, receiptLookup: Bool = false) async throws -> Value {
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
        catch { if Task.isCancelled { throw CancellationError() }; throw PersonalRoutineFailure.uncertain }
        guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 524_288 else { throw HouseholdFailure.invalid }
        if receiptLookup && response.statusCode == 404 { throw PersonalRoutineFailure.missingReceipt }
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401: throw HouseholdFailure.authentication
            case 403: throw HouseholdFailure.forbidden
            case 409: throw HouseholdFailure.conflict
            case 404, 503: throw HouseholdFailure.unavailable
            case 429: throw HouseholdFailure.rateLimited
            default: throw PersonalRoutineFailure.uncertain
            }
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

private final class PersonalRoutineRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
