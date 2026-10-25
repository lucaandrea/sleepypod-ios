import Foundation

// System actions use the same API as the app, and never send commands from its demo mode.
enum PodActions {
    // Task-scoped injection lets action tests avoid saved credentials and real devices.
    @TaskLocal static var suppliedClient: PodClient?
    static func client() throws -> PodClient {
        try AppMode.requireLiveConnection()
        if let suppliedClient { return suppliedClient }
        return try PodClient.configured()
    }
    static func setComfort(side: BedSide, mode: ComfortMode) async throws {
        struct Request: Encodable { var side: BedSide; var mode: String }
        try await client().post("comfort/mode", body: Request(side: side, mode: mode.rawValue))
    }
    static func temperature(side: BedSide, reading: TemperatureReading) async throws -> Double {
        let status: DeviceStatus = try await client().get("deviceStatus")
        return reading == .current ? status[side].currentTemperatureF : status[side].targetTemperatureF
    }
}
