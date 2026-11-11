import Foundation

protocol ArrangementMaintenanceTransport: Sendable {
    func session() async throws -> HouseholdSession
    func status(operationId: UUID?) async throws -> ArrangementMaintenanceStatus
    func cancellationPreview(operationId: UUID) async throws -> ArrangementCancellationPreview
    func send(_ request: ArrangementMaintenanceRequest, session: HouseholdSession) async throws -> ArrangementMaintenanceResult
}

/// Maintenance has fixed routes and a stable owner identity, but can follow its own assignment revision.
struct ArrangementMaintenanceHTTPClient: ArrangementMaintenanceTransport {
    let connection: PersonalBedConnection
    var transport: URLSession = Self.transport
    var clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: MaintenanceRedirectPolicy(), delegateQueue: nil)
    }()

    func session() async throws -> HouseholdSession {
        let current = try JSONDecoder().decode(HouseholdSession.self, from: await read("household/session"))
        try ArrangementMaintenanceValidation.owner(current, anchoredTo: connection.session)
        return current
    }
    func status(operationId: UUID? = nil) async throws -> ArrangementMaintenanceStatus {
        try ArrangementMaintenanceStatus.decodeExact(await read("household/transition", operationId: operationId))
    }
    func cancellationPreview(operationId: UUID) async throws -> ArrangementCancellationPreview {
        try ArrangementCancellationPreview.decodeExact(await read("household/transition/cancellation-preview", operationId: operationId))
    }
    func send(_ request: ArrangementMaintenanceRequest, session: HouseholdSession) async throws -> ArrangementMaintenanceResult {
        try ArrangementMaintenanceValidation.owner(session, anchoredTo: connection.session)
        let checked = try ArrangementMaintenanceRequest.decodeExact(request.body, action: request.action, session: session, now: clock())
        return try ArrangementMaintenanceResult.decodeExact(await read(checked.action.path, body: checked.body), request: checked)
    }
    private func read(_ path: String, operationId: UUID? = nil, body: Data? = nil) async throws -> Data {
        try connection.session.validate()
        guard connection.session.role == "owner", try HouseholdHTTPClient.endpoint(connection.endpoint.absoluteString) == connection.endpoint,
              HouseholdValidation.secret(connection.token) else { throw HouseholdFailure.authentication }
        let base = connection.endpoint.appending(path: "api/v1").appending(path: path)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw HouseholdFailure.invalid }
        if let operationId { components.queryItems = [URLQueryItem(name: "operationId", value: operationId.uuidString.lowercased())] }
        guard let url = components.url else { throw HouseholdFailure.invalid }
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

private final class MaintenanceRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
