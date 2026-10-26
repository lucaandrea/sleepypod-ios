import Foundation

// MARK: - WebSocket Sensor Frame Types

/// Discriminated union for all sensor frame types from ws://pod:3001
enum SensorFrame: Sendable {
    case piezoDual(PiezoDualFrame)
    case capSense2(CapSense2Frame)
    case capSense(CapSense2Frame)
    case bedTemp2(BedTemp2Frame)
    case bedTemp(BedTemp2Frame)
    case frzHealth(FrzHealthFrame)
    case frzTemp(FrzTemperatureFrame)
    case frzTherm(FrzThermalFrame)
    case log(LogFrame)
    case notification(NotificationFrame)
    case deviceStatus(DeviceStatusFrame)
    case gesture(GestureFrame)
    case unknown(String)

    var typeName: String {
        switch self {
        case .piezoDual: return "piezo-dual"
        case .capSense2: return "capSense2"
        case .capSense: return "capSense"
        case .bedTemp2: return "bedTemp2"
        case .bedTemp: return "bedTemp"
        case .frzHealth: return "frzHealth"
        case .frzTemp: return "frzTemp"
        case .frzTherm: return "frzTherm"
        case .log: return "log"
        case .notification: return "notification"
        case .deviceStatus: return "deviceStatus"
        case .gesture: return "gesture"
        case .unknown(let type): return type
        }
    }

    static func decode(from data: Data) -> SensorFrame? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        let decoder = JSONDecoder()
        switch type {
        case "piezo-dual":
            return (try? decoder.decode(PiezoDualFrame.self, from: data)).map { .piezoDual($0) }
        case "capSense2":
            return (try? decoder.decode(CapSense2Frame.self, from: data)).map { .capSense2($0) }
        case "capSense":
            return (try? decoder.decode(CapSense2Frame.self, from: data)).map { .capSense($0) }
        case "bedTemp2":
            return (try? decoder.decode(BedTemp2Frame.self, from: data)).map { .bedTemp2($0) }
        case "bedTemp":
            return (try? decoder.decode(LegacyBedTemperatureFrame.self, from: data)).map { .bedTemp($0.normalized) }
        case "frzTemp":
            return (try? decoder.decode(FrzTemperatureFrame.self, from: data)).map { .frzTemp($0) }
        case "frzTherm":
            return (try? decoder.decode(FrzThermalFrame.self, from: data)).map { .frzTherm($0) }
        case "frzHealth":
            return (try? decoder.decode(FrzHealthFrame.self, from: data)).map { .frzHealth($0) }
        case "log":
            return (try? decoder.decode(LogFrame.self, from: data)).map { .log($0) }
        case "notification":
            return (try? decoder.decode(NotificationFrame.self, from: data)).map { .notification($0) }
        case "deviceStatus":
            return (try? decoder.decode(DeviceStatusFrame.self, from: data)).map { .deviceStatus($0) }
        case "gesture":
            return (try? decoder.decode(GestureFrame.self, from: data)).map { .gesture($0) }
        default:
            return .unknown(type)
        }
    }
}

// MARK: - Gesture Frame (tap events from DAC monitor)

struct GestureFrame: Decodable, Sendable {
    let ts: Int
    let side: String
    let tapType: String
}

// MARK: - Piezo (~1 Hz, 500 samples per side)

struct PiezoDualFrame: Decodable, Sendable {
    let ts: Int
    let freq: Int
    let left1: [Int32]
    let right1: [Int32]
}

// MARK: - Capacitive Presence (~2 Hz)

struct CapSense2Frame: Decodable, Sendable {
    let ts: Int
    let left: CapSenseSide
    let right: CapSenseSide
}

struct CapSenseSide: Decodable, Sendable {
    let values: [Float]  // 8 values: [0:2]=A (head), [2:4]=B (torso), [4:6]=C (legs), [6:8]=REF
    let status: String

    init(values: [Float], status: String) { self.values = values; self.status = status }
    private enum CodingKeys: String, CodingKey { case values, status, out, cen, `in` }
    init(from decoder: Decoder) throws {
        if let fields = try? decoder.container(keyedBy: CodingKeys.self) {
            status = (try? fields.decode(String.self, forKey: .status)) ?? "unknown"
            if let channels = try? fields.decode([Float].self, forKey: .values) { values = channels }
            else if fields.contains(.out) || fields.contains(.cen) || fields.contains(.in) {
                // Retain missing channel positions; never shift another zone into a missing slot.
                values = [CodingKeys.out, .cen, .in].flatMap { key -> [Float] in
                    let value = (try? fields.decode(Float.self, forKey: key)) ?? -1
                    return [value, value]
                }
            } else { values = [] }
        } else {
            let field = try decoder.singleValueContainer()
            if let channels = try? field.decode([Float].self) { values = channels }
            else { values = [try field.decode(Float.self)] }
            status = "unknown"
        }
    }

    /// Raw channel averages (paired channels)
    var channelAverages: (a: Float, b: Float, c: Float, ref: Float) {
        guard values.count >= 8 else { return (0, 0, 0, 0) }
        return (
            (values[0] + values[1]) / 2,
            (values[2] + values[3]) / 2,
            (values[4] + values[5]) / 2,
            (values[6] + values[7]) / 2
        )
    }

    /// Presence zones with REF baseline subtracted, normalized 0–1
    /// Typical delta from REF is 13–24 pF when occupied
    var zones: (head: Float, torso: Float, legs: Float) {
        let ch = channelAverages
        let a = max(0, ch.a - ch.ref)
        let b = max(0, ch.b - ch.ref)
        let c = max(0, ch.c - ch.ref)
        let scale: Float = 30.0
        return (min(a / scale, 1), min(b / scale, 1), min(c / scale, 1))
    }

    /// Unreliable without calibrated baselines — prefer variance-based detection.
    /// This only checks if the sensor hardware is functioning.
    var sensorHealthy: Bool {
        status == "good"
    }
}

// MARK: - Bed Temperature (~0.06 Hz)

struct BedTemp2Frame: Decodable, Sendable {
    let ts: Int
    let mcu: Float?
    let left: BedTempSide
    let right: BedTempSide
}

struct BedTempSide: Decodable, Sendable {
    let amb: Float?   // ambient °C; unavailable sensors remain unknown
    let hu: Float?    // humidity %
    let temps: [Float]  // 4 zone temps °C

    /// Average valid surface temp in °F (filters -327 sentinel values)
    var avgSurfaceTempF: Int? {
        let valid = temps.filter { $0.isFinite && $0 > -100 }
        guard !valid.isEmpty else { return nil }
        let avgC = valid.reduce(0, +) / Float(valid.count)
        return Int(avgC * 9.0 / 5.0 + 32)
    }
}

/// Pod 3 uses centidegrees and flat zone keys; later Pods already send Celsius arrays.
private struct LegacyBedTemperatureFrame: Decodable {
    struct Zones: Decodable { let out: Float?; let cen: Float?; let `in`: Float? }
    let ts: Int
    let amb: Float?
    let hu: Float?
    let mcu: Float?
    let left: Zones
    let right: Zones
    private func converted(_ value: Float?) -> Float? {
        guard let value, value.isFinite, value != -32768 else { return nil }
        return value / 100
    }
    private func side(_ zones: Zones) -> BedTempSide {
        .init(amb: converted(amb), hu: converted(hu), temps: [zones.out, zones.cen, zones.in].map { converted($0) ?? -327.68 })
    }
    var normalized: BedTemp2Frame { .init(ts: ts, mcu: converted(mcu), left: side(left), right: side(right)) }
}

// MARK: - Freezer Health

struct FrzHealthFrame: Decodable, Sendable {
    let ts: Int
    let left: FrzSideHealth?
    let right: FrzSideHealth?
    let fan: FrzFanHealth?
}

struct FrzSideHealth: Decodable, Sendable {
    let tec: TecInfo?
    let pump: PumpInfo?
    var temps: FlowInfo?

    struct FlowInfo: Decodable, Sendable { let flowrate: Double? }

    struct TecInfo: Decodable, Sendable {
        let current: Float?
    }

    struct PumpInfo: Decodable, Sendable {
        let mode: String?
        let rpm: Int?
        let water: Bool?
        var duty: Double?
    }
}

struct FrzFanHealth: Decodable, Sendable {
    let top: FanInfo?
    let bottom: FanInfo?

    struct FanInfo: Decodable, Sendable {
        let rpm: Int?
    }
}

// MARK: - Log Frame

struct LogFrame: Decodable, Sendable {
    let ts: Int
    let level: String
    let msg: String
}

// MARK: - Notification Frame

struct NotificationFrame: Decodable, Sendable {
    let ts: Int
    let category: String
    let priority: String?
    let title: String
    let message: String
}

// MARK: - Device Status (from WS, ~2 Hz)

struct DeviceStatusFrame: Decodable, Sendable {
    let ts: Int
    let leftSide: WsSideStatus
    let rightSide: WsSideStatus
    let waterLevel: String
    let isPriming: Bool
    let snooze: WsSnoozeStatus?

    struct WsSideStatus: Decodable, Sendable {
        let currentTemperature: Double?
        let targetTemperature: Double?
        let currentLevel: Int
        let targetLevel: Int
        let heatingDuration: Int
        let isAlarmVibrating: Bool
    }

    struct WsSnoozeStatus: Decodable, Sendable {
        let left: WsSnoozeSide?
        let right: WsSnoozeSide?
    }

    struct WsSnoozeSide: Decodable, Sendable {
        let active: Bool
        let snoozeUntil: Int?
    }

    /// Convert to the app's DeviceStatus model for seamless integration.
    /// Fields not present in the WS frame (settings, coverVersion, etc.)
    /// are preserved from the last HTTP fetch.
    func toDeviceStatus(preserving existing: DeviceStatus?) -> DeviceStatus {
        DeviceStatus(
            left: SideStatus(
                currentTemperatureLevel: leftSide.currentLevel,
                currentTemperatureF: leftSide.currentTemperature.map { Int($0.rounded()) },
                targetTemperatureF: leftSide.targetTemperature.map { Int($0.rounded()) },
                secondsRemaining: leftSide.heatingDuration,
                isOn: leftSide.heatingDuration > 0,
                isAlarmVibrating: leftSide.isAlarmVibrating,
                taps: existing?.left.taps
            ),
            right: SideStatus(
                currentTemperatureLevel: rightSide.currentLevel,
                currentTemperatureF: rightSide.currentTemperature.map { Int($0.rounded()) },
                targetTemperatureF: rightSide.targetTemperature.map { Int($0.rounded()) },
                secondsRemaining: rightSide.heatingDuration,
                isOn: rightSide.heatingDuration > 0,
                isAlarmVibrating: rightSide.isAlarmVibrating,
                taps: existing?.right.taps
            ),
            waterLevel: waterLevel,
            isPriming: isPriming,
            settings: existing?.settings ?? DeviceHardwareSettings(v: 0, gainLeft: 0, gainRight: 0, ledBrightness: 0),
            coverVersion: existing?.coverVersion ?? "",
            hubVersion: existing?.hubVersion ?? "",
            freeSleep: existing?.freeSleep ?? FreeSleepInfo(version: "", branch: ""),
            wifiStrength: existing?.wifiStrength ?? 0,
            temperatureControl: existing?.temperatureControl,
            pumpStallNotifications: existing?.pumpStallNotifications,
            primeCompletedNotification: existing?.primeCompletedNotification,
            snooze: snooze.map { SidePair(
                left: $0.left.map { AlarmSnooze(active: $0.active, snoozeUntil: $0.snoozeUntil.map(Double.init)) },
                right: $0.right.map { AlarmSnooze(active: $0.active, snoozeUntil: $0.snoozeUntil.map(Double.init)) }
            ) } ?? existing?.snooze,
            roomClimate: existing?.roomClimate
        )
    }
}

// MARK: - Live Vitals (from DSP)

struct LiveVitals: Sendable {
    var heartRate: Double?
    var breathingRate: Double?
    var confidence: Double = 0
}

// MARK: - Utilities

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
