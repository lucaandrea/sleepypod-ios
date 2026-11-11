import Foundation

protocol PersonalJournalTransport: Sendable {
    func session() async throws -> HouseholdSession
    func read(date: String) async throws -> PersonalJournalPage
    func write(_ input: PersonalJournalWrite) async throws -> PersonalJournalResult
    func receipt(requestId: String) async throws -> PersonalJournalResult
}

struct PersonalJournalHTTPClient: PersonalJournalTransport {
    let connection: PersonalBedConnection
    var transport: URLSession = Self.transport
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PersonalHistoryRedirectPolicy(), delegateQueue: nil)
    }()
    func session() async throws -> HouseholdSession {
        try JSONDecoder().decode(HouseholdSession.self, from: await request("household/session"))
    }
    func read(date: String) async throws -> PersonalJournalPage {
        guard MorningJournalDates.valid(date) else { throw HouseholdFailure.invalid }
        return try .decodeExact(await request("me/journal", query: [.init(name: "date", value: date)]))
    }
    func write(_ input: PersonalJournalWrite) async throws -> PersonalJournalResult {
        try input.validate()
        return try .decodeExact(await request("me/journal", body: JSONEncoder().encode(input)))
    }
    func receipt(requestId: String) async throws -> PersonalJournalResult {
        guard HouseholdValidation.identifier(requestId) else { throw HouseholdFailure.invalid }
        return try .decodeExact(await request("me/journal/requests/\(requestId)"))
    }
    private func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard try HouseholdHTTPClient.endpoint(connection.endpoint.absoluteString) == connection.endpoint,
              HouseholdValidation.secret(connection.token) else { throw HouseholdFailure.authentication }
        guard path == "household/session" || connection.session.capabilities.personalJournal == true else { throw HouseholdFailure.unavailable }
        let endpoint = connection.endpoint.appending(path: "api/v1").appending(path: path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw HouseholdFailure.invalid }
        if !query.isEmpty { components.queryItems = query }
        guard let address = components.url else { throw HouseholdFailure.invalid }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(connection.session.selfSleeperId, forHTTPHeaderField: "X-Sleepypod-Sleeper-Id")
        do {
            let (bytes, response) = try await transport.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url == address else { throw HouseholdFailure.invalid }
            switch response.statusCode {
            case 200: break
            case 401: throw HouseholdFailure.authentication
            case 403: throw HouseholdFailure.forbidden
            case 409: throw HouseholdFailure.conflict
            case 404, 503: throw HouseholdFailure.unavailable
            case 429: throw HouseholdFailure.rateLimited
            default: throw HouseholdFailure.invalid
            }
            let maximumBytes = 524_288
            guard response.mimeType == "application/json", response.expectedContentLength <= maximumBytes else { throw HouseholdFailure.invalid }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw HouseholdFailure.invalid }; data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch let failure as HouseholdFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw HouseholdFailure.uncertain }
    }
}
