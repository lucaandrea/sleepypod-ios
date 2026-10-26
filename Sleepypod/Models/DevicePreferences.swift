import Foundation

// Scalar patches preserve explicit nulls while omitting every unchanged setting.
enum SettingsFieldValue: Codable, Sendable, Equatable {
    case string(String), integer(Int), boolean(Bool), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else { self = .string(try container.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
struct SettingsFieldPatch: Encodable, Sendable, Equatable {
    let fields: [String: SettingsFieldValue]
    var isEmpty: Bool { fields.isEmpty }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(fields) }
    func conflicts(original: [String: SettingsFieldValue], current: [String: SettingsFieldValue]) -> Bool {
        fields.keys.contains { original[$0] != current[$0] }
    }
}

struct DevicePreferences: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case timezone, temperatureUnit, timeFormat, defaultScheduleEndAction, globalMaxOnHours
        case rebootDaily, rebootTime, primePodDaily, primePodTime
        case ledNightModeEnabled, ledDayBrightness, ledNightBrightness, ledNightStartTime, ledNightEndTime
    }
    var timezone: String
    var temperatureUnit: String
    var timeFormat: String
    var defaultScheduleEndAction: String
    var globalMaxOnHours: Int?
    var rebootDaily: Bool
    var rebootTime: String?
    var primePodDaily: Bool
    var primePodTime: String?
    var ledNightModeEnabled: Bool
    var ledDayBrightness: Int
    var ledNightBrightness: Int
    var ledNightStartTime: String?
    var ledNightEndTime: String?

    var issue: String? {
        guard TimeZone(identifier: timezone) != nil else { return "Choose a valid timezone." }
        guard ["F", "C"].contains(temperatureUnit), ["12h", "24h"].contains(timeFormat),
              ["turn_off", "maintain"].contains(defaultScheduleEndAction) else { return "This Pod uses an unsupported preference value. Reload before editing." }
        guard globalMaxOnHours.map({ (1...48).contains($0) }) ?? true else { return "The power cap must be 1–48 hours, or turned off." }
        guard (0...100).contains(ledDayBrightness), (0...100).contains(ledNightBrightness) else { return "LED brightness must be 0–100%." }
        let clocks = [(rebootTime, rebootDaily), (primePodTime, primePodDaily), (ledNightStartTime, ledNightModeEnabled), (ledNightEndTime, ledNightModeEnabled)]
        guard clocks.allSatisfy({ clock, required in clock.map(Self.validClock) ?? !required }) else { return "Choose a valid time for each enabled schedule." }
        return nil
    }
    static func validClock(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }
    static func clockLocale(format: String, base: Locale = .current) -> Locale {
        var components = Locale.Components(locale: base)
        components.hourCycle = format == "24h" ? .zeroToTwentyThree : .oneToTwelve
        return Locale(components: components)
    }
    var fields: [String: SettingsFieldValue] {
        ["timezone": .string(timezone), "temperatureUnit": .string(temperatureUnit), "timeFormat": .string(timeFormat),
         "defaultScheduleEndAction": .string(defaultScheduleEndAction), "globalMaxOnHours": globalMaxOnHours.map(SettingsFieldValue.integer) ?? .null,
         "rebootDaily": .boolean(rebootDaily), "rebootTime": rebootTime.map(SettingsFieldValue.string) ?? .null,
         "primePodDaily": .boolean(primePodDaily), "primePodTime": primePodTime.map(SettingsFieldValue.string) ?? .null,
         "ledNightModeEnabled": .boolean(ledNightModeEnabled), "ledDayBrightness": .integer(ledDayBrightness),
         "ledNightBrightness": .integer(ledNightBrightness), "ledNightStartTime": ledNightStartTime.map(SettingsFieldValue.string) ?? .null,
         "ledNightEndTime": ledNightEndTime.map(SettingsFieldValue.string) ?? .null]
    }
    func patch(from saved: Self) -> SettingsFieldPatch { .init(fields: fields.filter { saved.fields[$0.key] != $0.value }) }
    static let demo = Self(timezone: "America/Los_Angeles", temperatureUnit: "F", timeFormat: "12h", defaultScheduleEndAction: "turn_off", globalMaxOnHours: 12, rebootDaily: false, rebootTime: "03:00", primePodDaily: false, primePodTime: "14:00", ledNightModeEnabled: false, ledDayBrightness: 80, ledNightBrightness: 5, ledNightStartTime: "22:00", ledNightEndTime: "07:00")
}

struct SensorSourceSnapshot: Decodable, Sendable {
    struct Firmware: Decodable, Sendable { let label: String; let detail: String; let expectedTransport: String; let probed: Bool }
    struct Stream: Decodable, Sendable {
        let source: String
        let override: String?
        let legacyNatsDisabled: Bool
        let lastFrameAgeMs: Double?
        let lastFrameType: String?
        let uptimeSeconds: Double
    }
    let firmware: Firmware
    let stream: Stream
    var sourceLabel: String {
        switch stream.source {
        case "raw": ".RAW files"
        case "nats": "NATS stream"
        case "pending": "Choosing…"
        default: "Unknown source"
        }
    }
    func status(elapsed: TimeInterval = 0) -> String {
        guard elapsed <= 25 else { return "Refresh needed" }
        if stream.source == "pending" { return "Choosing" }
        guard ["raw", "nats"].contains(stream.source) else { return "Unknown" }
        guard let age = stream.lastFrameAgeMs else { return stream.uptimeSeconds + elapsed < 90 ? "Waiting" : "No frames" }
        return age + max(0, elapsed) * 1000 > 60_000 ? "Stalled" : "Live"
    }
    var note: String? {
        if let override = stream.override { return "PIEZO_SENSOR_SOURCE=\(override) forces the source regardless of firmware." }
        if stream.legacyNatsDisabled { return "PIEZO_NATS_DISABLED=1 forces .RAW files regardless of firmware." }
        if stream.source != "pending" && stream.source != firmware.expectedTransport {
            return "The selected source differs from the firmware’s expected \(firmware.expectedTransport.uppercased()) transport. Service restart re-detects it."
        }
        return nil
    }
    static let demo = Self(firmware: .init(label: "NATS firmware", detail: "Simulated firmware probe", expectedTransport: "nats", probed: true), stream: .init(source: "nats", override: nil, legacyNatsDisabled: false, lastFrameAgeMs: 800, lastFrameType: "capSense2", uptimeSeconds: 1800))
}
