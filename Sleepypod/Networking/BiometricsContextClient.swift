import Foundation

protocol BiometricsContextClient: Sendable {
    func movement(side: Side, window: DateInterval) async throws -> [MovementBucket]
    func live(side: Side) async throws -> BiometricsLiveStatus
}

struct CoreBiometricsContextClient: BiometricsContextClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func movement(side: Side, window: DateInterval) async throws -> [MovementBucket] {
        let buckets: [MovementBucket] = try await client.get("biometrics/movement/buckets", query: [
            "side": side.rawValue, "startDate": window.start.ISO8601Format(), "endDate": window.end.ISO8601Format(), "bucketSeconds": "300", "limit": "10000"])
        // A full 31-day month is under 9,000 buckets. Report saturation instead of showing a truncated interval.
        guard buckets.count < 10000 else { throw APIError.serverError(message: "The movement interval was capped by the controller. Choose a shorter range.") }
        return buckets.filter { $0.side == side.rawValue && $0.date != nil }.sorted { $0.bucketStart < $1.bucketStart }
    }
    func live(side: Side) async throws -> BiometricsLiveStatus {
        struct Path: Decodable, Sendable { let occupancy: [String: String] }
        let client = try client
        async let sides: [String: BiometricPresence] = client.get("biometrics/occupancy")
        async let health: Path = client.get("health/data-path")
        async let latest: [VitalsRecord] = client.get("biometrics/vitals", query: ["side": side.rawValue, "limit": "1"])
        let (presence, path, records) = try await (sides, health, latest)
        return BiometricsLiveStatus(sides: presence, credibility: path.occupancy, latest: records.first?.date, checked: .now)
    }
}

struct DemoBiometricsContextClient: BiometricsContextClient {
    func movement(side: Side, window: DateInterval) async throws -> [MovementBucket] {
        stride(from: 0, to: Int(window.duration), by: 300).compactMap { seconds in
            guard seconds % 1800 == 0 else { return nil }
            return MovementBucket(side: side.rawValue, bucketStart: window.start.addingTimeInterval(Double(seconds)).ISO8601Format(), totalMovement: 250, eventCount: 1, sampleCount: 5)
        }
    }
    func live(side: Side) async throws -> BiometricsLiveStatus {
        let presence = BiometricPresence(occupied: false, available: true, classification: "none", movement: .init(active: false, peakScore: 0), level: .init(deviation: 0.3, ageMs: 1000))
        return BiometricsLiveStatus(sides: ["left": presence, "right": presence], credibility: ["left": "empty", "right": "empty"], latest: .now, checked: .now)
    }
}
