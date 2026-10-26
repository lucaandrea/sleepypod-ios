import Foundation

protocol NativePersonalActionClient: Sendable {
    func temperature(side: Side, current: Bool) async throws -> Double
    func away(side: Side, enabled: Bool) async throws
    func prime() async throws
}

/// These accepted Core routes have no durable control receipt; never retry a mutation automatically.
struct CoreNativePersonalActionClient: NativePersonalActionClient {
    let transport: CoreRESTClient
    func temperature(side: Side, current: Bool) async throws -> Double {
        struct Capability: Decodable, Sendable {
            struct Observation: Decodable, Sendable { let freshness: String; let expiresAt: String? }
            struct Observations: Decodable, Sendable { let device: Observation }
            let apiVersion: Int; let generatedAt: String; let observations: Observations
        }
        struct Reading: Decodable, Sendable { let currentTemperature: Double?; let targetTemperature: Double? }
        struct Status: Decodable, Sendable { let leftSide: Reading; let rightSide: Reading }
        let started = ContinuousClock.now
        let capability: Capability = try await send("v1/capabilities", method: "GET")
        guard capability.apiVersion == 1, capability.observations.device.freshness == "fresh",
              let generated = NextAlarmState.instant(capability.generatedAt),
              let expiry = capability.observations.device.expiresAt.flatMap(NextAlarmState.instant), expiry > generated else {
            throw APIError.serverError(message: "The controller has no fresh temperature report. Open the app to check its connection.")
        }
        let status: Status = try await send("device/status", method: "GET", query: ["unit": "F"])
        guard started.duration(to: .now) < .seconds(expiry.timeIntervalSince(generated)) else {
            throw APIError.serverError(message: "The temperature report expired while loading. Read it again.")
        }
        let reading = side == .left ? status.leftSide : status.rightSide
        guard let value = current ? reading.currentTemperature : reading.targetTemperature, value.isFinite else {
            throw APIError.serverError(message: "This temperature reading is unavailable. No value has been substituted.")
        }
        return value
    }
    func away(side: Side, enabled: Bool) async throws {
        struct Input: Encodable, Sendable { let side: Side; let awayMode: Bool }
        struct Result: Decodable, Sendable { let side: Side; let awayMode: Bool }
        let result: Result = try await send("settings/side", method: "PATCH", body: JSONEncoder().encode(Input(side: side, awayMode: enabled)))
        guard result.side == side, result.awayMode == enabled else { throw NativeControlFailure.invalid }
    }
    func prime() async throws {
        struct Result: Decodable, Sendable { let success: Bool }
        let result: Result = try await send("device/prime", method: "POST", body: Data("{}".utf8))
        guard result.success else { throw APIError.serverError(message: "The controller did not accept the priming request.") }
    }
    private func send<Result: Decodable & Sendable>(_ path: String, method: String, query: [String: String] = [:], body: Data? = nil) async throws -> Result {
        var request = try transport.request(path, method: method, query: query, body: body)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await transport.session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 262_144 else { throw NativeControlFailure.invalid }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.serverError(message: response.statusCode == 401 ? "The controller rejected the connection key."
                : "The controller response could not be confirmed (HTTP \(response.statusCode)). Open the app to review its current state before trying again.")
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
