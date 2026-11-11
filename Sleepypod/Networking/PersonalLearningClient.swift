import Foundation

protocol PersonalLearningTransport: Sendable {
    func session() async throws -> HouseholdSession
    func archives(before: String?, limit: Int) async throws -> PersonalLearningArchivePage
    func records(archiveId: String, after: Int, limit: Int) async throws -> PersonalLearningRecordPage
    func detail(recordId: String) async throws -> PersonalLearningDetail
}

/// Read-only personal routes use bounded streams, pinned identity and no owner fallback.
struct PersonalLearningHTTPClient: PersonalLearningTransport {
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
    func archives(before: String?, limit: Int = 20) async throws -> PersonalLearningArchivePage {
        try available()
        guard (1...50).contains(limit), before.map(HouseholdValidation.identifier) ?? true else { throw HouseholdFailure.invalid }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try .decodeExact(await read("me/learning/archives", query: query))
    }
    func records(archiveId: String, after: Int, limit: Int = 20) async throws -> PersonalLearningRecordPage {
        try available()
        guard HouseholdValidation.identifier(archiveId), (0...100_000).contains(after), (1...50).contains(limit) else { throw HouseholdFailure.invalid }
        return try .decodeExact(await read("me/learning/records", query: [
            .init(name: "archiveId", value: archiveId), .init(name: "after", value: String(after)), .init(name: "limit", value: String(limit))
        ]))
    }
    func detail(recordId: String) async throws -> PersonalLearningDetail {
        try available()
        guard HouseholdValidation.identifier(recordId) else { throw HouseholdFailure.invalid }
        return try .decodeExact(await read("me/learning/records/\(recordId)", maximumBytes: 2 * PersonalLearningContract.recordBytes + 65_536))
    }
    private func available() throws {
        guard connection.session.capabilities.personalLearningArchive == true else { throw HouseholdFailure.unavailable }
    }
    private func read(_ path: String, query: [URLQueryItem] = [], maximumBytes: Int = 524_288) async throws -> Data {
        guard try HouseholdHTTPClient.endpoint(connection.endpoint.absoluteString) == connection.endpoint,
              HouseholdValidation.secret(connection.token) else { throw HouseholdFailure.authentication }
        let endpoint = connection.endpoint.appending(path: "api/v1").appending(path: path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw HouseholdFailure.invalid }
        if !query.isEmpty { components.queryItems = query }
        guard let address = components.url else { throw HouseholdFailure.invalid }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            guard response.mimeType == "application/json", response.expectedContentLength <= maximumBytes else { throw HouseholdFailure.invalid }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw HouseholdFailure.invalid }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch let failure as HouseholdFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw HouseholdFailure.uncertain }
    }
}
