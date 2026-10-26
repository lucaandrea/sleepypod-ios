import Foundation

protocol TemperatureApplicationClient: Sendable {
    func available() async throws
    func read(side: Side, before: Int?) async throws -> TemperatureApplicationPage
}
struct CoreTemperatureApplicationClient: TemperatureApplicationClient {
    private struct Capabilities: Decodable, Sendable {
        struct Endpoints: Decodable, Sendable { let temperatureApplications: String? }
        struct Feature: Decodable, Sendable { let implemented: Bool; let runtime: String }
        struct Features: Decodable, Sendable { let temperatureApplicationHistory: Feature? }
        let apiVersion: Int
        let endpoints: Endpoints?
        let features: Features?
    }
    let transport: CoreRESTClient
    func available() async throws {
        let value: Capabilities = try await get("v1/capabilities")
        guard value.apiVersion == 1, value.endpoints?.temperatureApplications == "/api/v1/device/temperature/applications",
              value.features?.temperatureApplicationHistory?.implemented == true,
              value.features?.temperatureApplicationHistory?.runtime == "ready" else {
            throw APIError.serverError(message: "This controller does not offer temperature application history yet.")
        }
    }
    func read(side: Side, before: Int?) async throws -> TemperatureApplicationPage {
        var query = ["side": side.rawValue]
        if let before {
            guard (1...9_007_199_254_740_991).contains(before) else { throw TemperatureApplicationPage.invalid }
            query["beforeId"] = String(before)
        }
        let page: TemperatureApplicationPage = try await get("v1/device/temperature/applications", query: query)
        try page.validate(side: side, before: before); return page
    }
    private func get<Value: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> Value {
        var request = try transport.request(path, method: "GET", query: query)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await transport.session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw TemperatureApplicationPage.invalid }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.serverError(message: response.statusCode == 401 ? "The controller rejected the connection key."
                : "Temperature application history is unavailable (HTTP \(response.statusCode)).")
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
