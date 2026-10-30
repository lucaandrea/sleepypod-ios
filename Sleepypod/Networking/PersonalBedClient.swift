import Foundation

struct PersonalBedConnection: Sendable {
    let id: UUID
    let endpoint: URL
    let token: String
    let session: HouseholdSession
}

protocol PersonalBedTransport: Sendable {
    func session() async throws -> HouseholdSession
    func bed() async throws -> PersonalBed
    func submit(_ body: Data) async throws -> PersonalControlReceipt
    func receipt(_ requestId: UUID) async throws -> PersonalControlReceipt
}

enum PersonalControlFailure: Error, LocalizedError {
    case missingReceipt, recoveryCapacity, connectionUncertain, supersededByStop
    var errorDescription: String? {
        switch self {
        case .supersededByStop: "The earlier adjustment was cancelled before sending because you pressed Stop. Check the Stop receipt and the bed."
        case .missingReceipt: "No receipt is available. The saved command has not been resent; its outcome remains uncertain."
        case .connectionUncertain: "The connection ended before a result could be confirmed. Check any pending receipt and the bed before another adjustment. Saved commands will not be resent."
        case .recoveryCapacity: "Command recovery storage is full. Review earlier commands in your paired accounts or erase local personal data before another command. No new command was sent."
        }
    }
    static func message(for error: Error) -> String {
        if error as? HouseholdFailure == .uncertain { return Self.connectionUncertain.localizedDescription }
        return (error as? LocalizedError)?.errorDescription ?? Self.connectionUncertain.localizedDescription
    }
}

/// Fixed personal routes, explicit credentials, no owner fallback, cookies, cache or redirects.
struct PersonalBedHTTPClient: PersonalBedTransport {
    let connection: PersonalBedConnection
    var transport: URLSession = Self.transport
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: PersonalBedRedirectPolicy(), delegateQueue: nil)
    }()
    func session() async throws -> HouseholdSession { try await read("household/session") }
    func bed() async throws -> PersonalBed { try await read("me/bed") }
    func receipt(_ requestId: UUID) async throws -> PersonalControlReceipt {
        try await read("me/controls/\(requestId.uuidString.lowercased())", receiptLookup: true)
    }
    func submit(_ body: Data) async throws -> PersonalControlReceipt {
        let request = try JSONDecoder().decode(PersonalControlRequest.self, from: body)
        try request.validate()
        guard request.scope.matches(connection.session) else { throw HouseholdFailure.changedIdentity }
        return try await read("me/controls", body: body)
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
        catch { if Task.isCancelled { throw CancellationError() }; throw HouseholdFailure.uncertain }
        guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 524_288 else { throw HouseholdFailure.invalid }
        if receiptLookup && response.statusCode == 404 { throw PersonalControlFailure.missingReceipt }
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401: throw HouseholdFailure.authentication
            case 403: throw HouseholdFailure.forbidden
            case 409: throw HouseholdFailure.conflict
            case 404, 503: throw HouseholdFailure.unavailable
            case 429: throw HouseholdFailure.rateLimited
            default: throw HouseholdFailure.uncertain
            }
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

private final class PersonalBedRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
