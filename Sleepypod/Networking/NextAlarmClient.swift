import Foundation

protocol NextAlarmClient: Sendable {
    func available() async throws
    func read(side: Side) async throws -> NextAlarmState
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState
}
protocol LaterWakeClient: NextAlarmClient {
    func laterAvailable() async throws
    func previewLater(_ input: LaterWakeRequest) async throws -> LaterWakePacket
    func applyLater(_ packet: LaterWakePacket) async throws -> NextAlarmState
}
struct CoreNextAlarmClient: LaterWakeClient {
    private struct Capabilities: Decodable, Sendable {
        struct Features: Decodable, Sendable {
            struct Feature: Decodable, Sendable { let implemented: Bool; let runtime: String }
            let nextAlarmOverride: Feature?
            let laterAlarmPreview: Feature?
        }
        struct Endpoints: Decodable, Sendable {
            let nextAlarm: String?; let alarmOverride: String?
            let laterAlarmPreview: String?; let laterAlarmApply: String?
        }
        let apiVersion: Int
        let features: Features
        let endpoints: Endpoints
    }
    let transport: CoreRESTClient
    var now: @Sendable () -> Date = { Date() }
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
        try JSONDecoder().decode(Result.self, from: await responseData(path, method: method, query: query, body: body))
    }
    private func responseData(_ path: String, method: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
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
        return data
    }
    func laterAvailable() async throws {
        let result: Capabilities = try await send("v1/capabilities", method: "GET")
        guard result.apiVersion == 1, result.features.laterAlarmPreview?.implemented == true,
              result.features.laterAlarmPreview?.runtime == "ready",
              result.endpoints.laterAlarmPreview == "/api/v1/alarm/later-preview",
              result.endpoints.laterAlarmApply == "/api/v1/alarm/later-apply" else {
            throw NextAlarmFailure.unavailable("Update the controller to review a later wake. Your existing alarm is unchanged.")
        }
    }
    func previewLater(_ input: LaterWakeRequest) async throws -> LaterWakePacket {
        let data = try await responseData("v1/alarm/later-preview", method: "POST", body: JSONEncoder().encode(input))
        return try LaterWakePacket(data: data, input: input, now: now())
    }
    func applyLater(_ packet: LaterWakePacket) async throws -> NextAlarmState {
        let result: NextAlarmState = try await send("v1/alarm/later-apply", method: "POST", body: packet.application(now: now()))
        try packet.preview.validateSaved(result)
        return result
    }
}
