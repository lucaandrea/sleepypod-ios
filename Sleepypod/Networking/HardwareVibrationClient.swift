import Foundation

protocol HardwareVibrationClient: Sendable {
    func play(_ request: HardwareVibrationRequest) async throws -> Bool
    func stop(_ side: Side) async throws -> Bool
}
struct CoreHardwareVibrationClient: HardwareVibrationClient {
    private struct Response: Decodable, Sendable { let success: Bool }
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func play(_ request: HardwareVibrationRequest) async throws -> Bool {
        try request.validate()
        let result: Response = try await client.post("device/alarm", body: request, returning: Response.self)
        return result.success
    }
    func stop(_ side: Side) async throws -> Bool {
        let result: Response = try await client.post("device/alarm/clear", body: ["side": side.rawValue], returning: Response.self)
        return result.success
    }
}
struct LegacyHardwareVibrationClient: HardwareVibrationClient {
    let api: any SleepypodProtocol
    func play(_ request: HardwareVibrationRequest) async throws -> Bool {
        try request.validate()
        try await api.triggerAlarm(.init(side: request.side, vibrationIntensity: request.vibrationIntensity, vibrationPattern: .rise, duration: request.duration, force: true))
        return true
    }
    func stop(_ side: Side) async throws -> Bool { try await api.clearAlarm(side: side); return true }
}
actor DemoHardwareVibrationClient: HardwareVibrationClient {
    func play(_ request: HardwareVibrationRequest) throws -> Bool { try request.validate(); return true }
    func stop(_ side: Side) -> Bool { true }
}
