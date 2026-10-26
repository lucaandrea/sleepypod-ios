import Foundation

/// Firmware freezer temperature values are centidegrees, unlike bedTemp2 Celsius arrays.
struct FrzTemperatureFrame: Decodable, Sendable {
    let ts: Int
    let left: Double?
    let right: Double?
    let amb: Double?
    let hs: Double?
    static func celsius(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, abs(raw + 32768) >= 1 else { return nil }
        return raw / 100
    }
    var reading: SensorFreezerReading {
        .init(timestamp: Date(timeIntervalSince1970: Double(ts)).ISO8601Format(), ambientTemp: Self.celsius(amb),
              heatsinkTemp: Self.celsius(hs), leftWaterTemp: Self.celsius(left), rightWaterTemp: Self.celsius(right))
    }
}

struct FrzThermalFrame: Decodable, Sendable {
    struct Control: Decodable, Sendable {
        let power: Double?
        let target: Double?
        let valid: Bool?
        let enabled: Bool?
        private enum CodingKeys: String, CodingKey { case power, target, valid, enabled }
        init(from decoder: Decoder) throws {
            if let number = try? decoder.singleValueContainer().decode(Double.self) {
                power = number; target = nil; valid = nil; enabled = nil
            } else {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                power = try fields.decodeIfPresent(Double.self, forKey: .power)
                target = try fields.decodeIfPresent(Double.self, forKey: .target)
                valid = try fields.decodeIfPresent(Bool.self, forKey: .valid)
                enabled = try fields.decodeIfPresent(Bool.self, forKey: .enabled)
            }
        }
    }
    let ts: Int
    let left: Control?
    let right: Control?
}

extension SensorFrame {
    var measuredAt: Date? {
        let timestamp: Int
        switch self {
        case .piezoDual(let frame): timestamp = frame.ts
        case .capSense(let frame), .capSense2(let frame): timestamp = frame.ts
        case .bedTemp(let frame), .bedTemp2(let frame): timestamp = frame.ts
        case .frzHealth(let frame): timestamp = frame.ts
        case .frzTemp(let frame): timestamp = frame.ts
        case .frzTherm(let frame): timestamp = frame.ts
        case .deviceStatus(let frame): timestamp = frame.ts
        case .gesture(let frame): timestamp = frame.ts
        case .log(let frame): timestamp = frame.ts
        case .notification(let frame): timestamp = frame.ts
        case .unknown: return nil
        }
        return timestamp > 0 ? Date(timeIntervalSince1970: Double(timestamp)) : nil
    }
}
