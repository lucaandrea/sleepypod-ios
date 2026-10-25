import Foundation

struct CoreRESTClient: Sendable {
    let endpoint: URL
    var session: URLSession = OwnerConnection.session

    static func configured() throws -> Self {
        if let endpoint = OwnerConnection.endpoint { return Self(endpoint: endpoint) }
        guard let host = UserDefaults.standard.string(forKey: "podIPAddress"), !host.isEmpty,
              let endpoint = URL(string: "http://\(host):3000") else { throw APIError.noBaseURL }
        return Self(endpoint: endpoint)
    }

    func get<Result: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> Result {
        try JSONDecoder().decode(Result.self, from: await send(path, method: "GET", query: query))
    }
    func post<Body: Encodable & Sendable>(_ path: String, body: Body) async throws {
        _ = try await send(path, method: "POST", body: JSONEncoder().encode(body))
    }
    func post<Body: Encodable & Sendable, Result: Decodable & Sendable>(_ path: String, body: Body, returning: Result.Type) async throws -> Result {
        try JSONDecoder().decode(Result.self, from: await send(path, method: "POST", body: JSONEncoder().encode(body)))
    }
    func patch<Body: Encodable & Sendable>(_ path: String, body: Body) async throws {
        _ = try await send(path, method: "PATCH", body: JSONEncoder().encode(body))
    }
    func put<Body: Encodable & Sendable, Result: Decodable & Sendable>(_ path: String, body: Body, returning: Result.Type) async throws -> Result {
        try JSONDecoder().decode(Result.self, from: await send(path, method: "PUT", body: JSONEncoder().encode(body)))
    }
    func delete(_ path: String, query: [String: String] = [:]) async throws {
        _ = try await send(path, method: "DELETE", query: query)
    }

    /// Build query items separately so values containing spaces, '&' or timestamps stay data.
    func request(_ path: String, method: String, query: [String: String] = [:], body: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint.appending(path: "api").appending(path: path), resolvingAgainstBaseURL: false) else {
            throw APIError.noBaseURL
        }
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw APIError.noBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return OwnerConnection.authorize(request)
    }

    private func send(_ path: String, method: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        let (data, response) = try await session.data(for: request(path, method: method, query: query, body: body))
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse(statusCode: 0) }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let message: String? }
            let detail = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            throw APIError.serverError(message: response.statusCode == 401
                ? "The controller rejected the connection key."
                : detail.map { String($0.prefix(400)) } ?? "Controller request failed (HTTP \(response.statusCode)).")
        }
        return data
    }
}
