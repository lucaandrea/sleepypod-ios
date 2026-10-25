import Foundation

struct PodClient: Sendable {
    private static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    let baseURL: URL
    let token: String
    private let transport: URLSession
    private let apiPrefix: String

    static func configured() throws -> PodClient {
        let address = UserDefaults.standard.string(forKey: "podURL") ?? ""
        let prefix = UserDefaults.standard.string(forKey: "podNativeAPIPrefix") ?? ""
        return try PodClient(address: address, token: TokenStore.read(for: address), apiPrefix: prefix)
    }
    init(address: String, token: String, apiPrefix: String = "") throws {
        try self.init(address: address, token: token, session: Self.session, apiPrefix: apiPrefix)
    }
    init(address: String, token: String, session: URLSession, apiPrefix: String = "") throws {
        baseURL = try ConnectionEndpoint.url(address); self.token = token; transport = session
        // Keep the selected API contract stable for the lifetime of this connection.
        self.apiPrefix = apiPrefix
    }

    private func request(_ route: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        try AppMode.requireLiveConnection()
        var components = URLComponents(url: baseURL.appending(path: "api").appending(path: apiPrefix).appending(path: route), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = route == "ai/coach" ? 50 : 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PodError.message("No response from the Pod.") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw PodError.message("The connection token was not accepted.") }
            if response.statusCode == 503 { throw PodError.message("The server is reachable, but the Pod is unavailable.") }
            if response.statusCode == 404, apiPrefix == "native/v1" {
                throw PodError.message("This Core controller has not enabled this feature service yet. Temperature, alarms and bed position remain available in the main controls.")
            }
            let failure = try? JSONDecoder().decode(APIError.self, from: data)
            throw PodError.message(failure?.error.message ?? "The Pod returned an error (\(response.statusCode)).")
        }
        return data
    }
    func get<Result: Decodable & Sendable>(_ route: String, query: [URLQueryItem] = []) async throws -> Result {
        try JSONDecoder().decode(Result.self, from: await request(route, method: "GET", query: query))
    }
    func post<Body: Encodable & Sendable>(_ route: String, body: Body) async throws {
        _ = try await request(route, method: "POST", body: JSONEncoder().encode(body))
    }
    func postReturning<Result: Decodable & Sendable, Body: Encodable & Sendable>(_ route: String, body: Body) async throws -> Result {
        try JSONDecoder().decode(Result.self, from: await request(route, method: "POST", body: JSONEncoder().encode(body)))
    }
    func action(_ route: String) async throws { _ = try await request(route, method: "POST", body: Data("{}".utf8)) }
    func editRecord(_ id: Int, change: SleepRecordChange) async throws {
        _ = try await request("analytics/episodes/\(id)", method: "PUT", body: JSONEncoder().encode(change))
    }
    func deleteRecord(_ id: Int, identity: SleepRecordIdentity) async throws {
        _ = try await request("analytics/episodes/\(id)", method: "DELETE", body: JSONEncoder().encode(identity))
    }
    func coach(side: BedSide, provider: String, share: Bool, question: String, days: Int = 30) async throws -> Coaching {
        struct Body: Encodable { var side: String; var provider: String; var shareSummary: Bool; var question: String; var days: Int }
        let body = Body(side: side.rawValue, provider: provider, shareSummary: share, question: question, days: days)
        return try JSONDecoder().decode(Coaching.self, from: await request("ai/coach", method: "POST", body: JSONEncoder().encode(body)))
    }
    func healthExport<Record: Decodable & Sendable & Identifiable>(kind: String, query: [URLQueryItem]) async throws -> [Record] where Record.ID == Int {
        var records: [Record] = []
        var cursor = 0
        while true {
            try Task.checkCancellation()
            let page: HealthExportPage<Record> = try await get("health/export", query: query + [
                URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "afterId", value: String(cursor))])
            let identifiers = page.records.map(\.id)
            guard identifiers == identifiers.sorted(), Set(identifiers).count == identifiers.count,
                  identifiers.allSatisfy({ $0 > cursor }), records.count + page.records.count <= 200_000 else {
                throw PodError.message("Health export returned inconsistent or excessive records. Retry with a shorter period.")
            }
            records.append(contentsOf: page.records)
            guard let next = page.nextCursor else { return records }
            guard next > cursor, next == identifiers.last else { throw PodError.message("Health export returned an inconsistent cursor. Retry the sync.") }
            cursor = next
        }
    }
    private struct APIError: Decodable { struct Detail: Decodable { var message: String }; var error: Detail }
}

private struct HealthExportPage<Record: Decodable & Sendable>: Decodable, Sendable { var records: [Record]; var nextCursor: Int? }

final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
