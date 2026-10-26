import Foundation

protocol NextAlarmClient: Sendable {
    func available() async throws
    func read(side: Side) async throws -> NextAlarmState
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState
}
struct CoreNextAlarmClient: NextAlarmClient {
    private struct Capabilities: Decodable, Sendable {
        struct Features: Decodable, Sendable {
            struct Feature: Decodable, Sendable { let implemented: Bool; let runtime: String }
            let nextAlarmOverride: Feature?
        }
        struct Endpoints: Decodable, Sendable { let nextAlarm: String?; let alarmOverride: String? }
        let apiVersion: Int
        let features: Features
        let endpoints: Endpoints
    }
    let transport: CoreRESTClient
    func available() async throws {
        let result: Capabilities = try await send("v1/capabilities", method: "GET")
        guard result.apiVersion == 1, result.features.nextAlarmOverride?.implemented == true,
              result.features.nextAlarmOverride?.runtime == "ready", result.endpoints.nextAlarm == "/api/v1/alarm/next",
              result.endpoints.alarmOverride == "/api/v1/alarm/override" else {
            throw NextAlarmFailure.unavailable("Update the controller to change one alarm at a time. Your weekly schedule is still available.")
        }
    }
    func read(side: Side) async throws -> NextAlarmState {
        let result: NextAlarmState = try await send("v1/alarm/next", method: "GET", query: ["side": side.rawValue])
        try result.validate(side: side); return result
    }
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState {
        let result: NextAlarmState = try await send("v1/alarm/override", method: "POST", body: JSONEncoder().encode(input))
        try result.validate(side: input.side, write: true); return result
    }
    private func send<Result: Decodable & Sendable>(_ path: String, method: String, query: [String: String] = [:], body: Data? = nil) async throws -> Result {
        var request = try transport.request(path, method: method, query: query, body: body)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await transport.session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 262_144 else { throw NextAlarmFailure.invalid }
        if response.statusCode == 409 { throw NextAlarmFailure.conflict }
        guard (200..<300).contains(response.statusCode) else {
            let message = response.statusCode == 401 ? "The controller rejected the connection key."
                : response.statusCode == 412 ? "Set the Pod timezone before changing this alarm."
                : response.statusCode == 400 ? "Choose a future time on this wake date, before the following alarm. Repeated or skipped daylight-saving times cannot be used."
                : "The alarm change could not be confirmed (HTTP \(response.statusCode))."
            throw NextAlarmFailure.unavailable(message)
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
