import Foundation

protocol SensorCalibrationClient: Sendable {
    func status(_ side: Side) async throws -> SensorCalibrationStatus
    func trigger(_ target: CalibrationTarget?) async throws -> CalibrationTriggerResponse
}

struct CoreSensorCalibrationClient: SensorCalibrationClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func status(_ side: Side) async throws -> SensorCalibrationStatus {
        try await client.get("calibration/status", query: ["side": side.rawValue])
    }
    func trigger(_ target: CalibrationTarget?) async throws -> CalibrationTriggerResponse {
        if let target {
            return try await client.post("calibration/trigger", body: ["side": target.side.rawValue, "sensorType": target.kind.rawValue], returning: CalibrationTriggerResponse.self)
        }
        return try await client.post("calibration/trigger-all", body: [String: String](), returning: CalibrationTriggerResponse.self)
    }
}

actor DemoSensorCalibrationClient: SensorCalibrationClient {
    private var revision = 0
    private let original = Date.now.addingTimeInterval(-24 * 3600)
    private var updates: [CalibrationTarget: Date] = [:]
    func status(_ side: Side) throws -> SensorCalibrationStatus {
        var profiles: [String: Any] = [:]
        for (index, kind) in CalibrationKind.allCases.enumerated() {
            let start = updates[.init(side: side, kind: kind)] ?? original
            let created = SensorCalibrationProfile.formatter.string(from: start)
            let parameters: [String: Any]
            switch kind {
            case .piezo: parameters = ["baseline_mean_range": 6000, "presence_threshold": 45000]
            case .capacitance: parameters = ["format": "capSense2", "threshold": 6, "channels": ["A": ["mean": 2.0, "std": 0.2], "B": ["mean": 2.0, "std": 0.2], "C": ["mean": 2.0, "std": 0.2]], "ref": ["mean": 1.16]]
            case .temperature: parameters = ["ambient_mean": 2200, "offsets": ["\(side.rawValue)_outer_temp": 100, "\(side.rawValue)_center_temp": 200, "\(side.rawValue)_inner_temp": 150]]
            }
            profiles[kind.rawValue] = ["id": index + (side == .left ? 1 : 4), "side": side.rawValue, "sensorType": kind.rawValue, "status": "completed", "qualityScore": 0.91 - Double(index) * 0.04, "samplesUsed": 1000 + index * 300, "createdAt": created, "expiresAt": start.addingTimeInterval(48 * 3600).ISO8601Format(), "parameters": parameters]
        }
        return try JSONDecoder().decode(SensorCalibrationStatus.self, from: JSONSerialization.data(withJSONObject: profiles))
    }
    func trigger(_ target: CalibrationTarget?) -> CalibrationTriggerResponse {
        revision += 1
        for side in Side.allCases { for kind in CalibrationKind.allCases {
            let candidate = CalibrationTarget(side: side, kind: kind)
            if target == nil || target == candidate { updates[candidate] = .now.addingTimeInterval(Double(revision) / 1000) }
        } }
        return .init(triggered: true, message: "Simulated calibration queued")
    }
}
