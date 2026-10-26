import Foundation

enum HomeRoomMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case temperature, humidity, co2, pm25, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperature: "Room temperature"
        case .humidity: "Humidity"
        case .co2: "Carbon dioxide"
        case .pm25: "Fine particles"
        case .light: "Room light"
        }
    }
    var symbol: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .humidity: "humidity"
        case .co2: "wind"
        case .pm25: "aqi.medium"
        case .light: "sun.max"
        }
    }
    var unit: String {
        switch self {
        case .temperature: "°F"
        case .humidity: "%"
        case .co2: "ppm"
        case .pm25: "µg/m³"
        case .light: "lx"
        }
    }
    var sourceUnits: [String] {
        switch self {
        case .temperature: ["°C", "°F"]
        case .pm25: ["µg/m³", "μg/m³"]
        case .light: ["lx", "lux"]
        default: [unit]
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .temperature: -40...140
        case .humidity: 0...100
        case .co2: 0...10_000
        case .pm25: 0...2_000
        case .light: 0...200_000
        }
    }
}
enum RoomTimestampFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case iso8601, unixSeconds = "unix_seconds", unixMilliseconds = "unix_milliseconds"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iso8601: "ISO 8601 with timezone"
        case .unixSeconds: "Unix seconds"
        case .unixMilliseconds: "Unix milliseconds"
        }
    }
}
struct HomeRoomMapping: Codable, Equatable, Identifiable, Sendable {
    var metric: HomeRoomMetric
    var entityId: String
    var unit: String
    var timestampAttribute: String
    var timestampFormat: RoomTimestampFormat
    var maxAgeSeconds: Int
    var id: HomeRoomMetric { metric }
    static func blank(_ metric: HomeRoomMetric) -> Self {
        .init(metric: metric, entityId: "", unit: metric.sourceUnits[0], timestampAttribute: "", timestampFormat: .iso8601, maxAgeSeconds: 120)
    }
    func validate() throws {
        guard entityId.range(of: "^sensor\\.[a-z0-9_]{1,100}$", options: .regularExpression) != nil,
              timestampAttribute.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,63}$", options: .regularExpression) != nil,
              metric.sourceUnits.contains(unit), (30...900).contains(maxAgeSeconds) else {
            throw HomeRoomStatus.issue("Check \(metric.title.lowercased()): use a sensor entity, its source unit, a measurement timestamp attribute, and an age from 30 to 900 seconds.")
        }
    }
}
struct HomeRoomConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var roomName: String
    var mappings: [HomeRoomMapping]
    static let empty = Self(enabled: false, roomName: "Bedroom", mappings: [])
    func validated() throws -> Self {
        var result = self; result.roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(result.roomName.utf16.count), mappings.count <= 5, !enabled || !mappings.isEmpty,
              Set(mappings.map(\.metric)).count == mappings.count, Set(mappings.map(\.entityId)).count == mappings.count else {
            throw HomeRoomStatus.issue("Use a room name of 1–60 characters and one unique entity per measurement. Select a sensor before enabling input.")
        }
        for mapping in mappings { try mapping.validate() }; return result
    }
}
struct HomeRoomVersion: Codable, Equatable, Sendable { let revision: Int64; let config: HomeRoomConfiguration }
struct HomeRoomObservation: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case fresh, disabled, disconnected, waiting, unavailable, stale, clockInvalid = "clock_invalid"
        var title: String {
            switch self {
            case .fresh: "Fresh measurement"
            case .disabled: "Input disabled"
            case .disconnected: "Broker disconnected"
            case .waiting: "Waiting for a new measurement"
            case .unavailable: "Sensor unavailable"
            case .stale: "Measurement expired"
            case .clockInvalid: "Check source clocks"
            }
        }
    }
    let metric: HomeRoomMetric
    let entityId: String
    let unit: String
    let value: Double?
    let lastValue: Double?
    let measuredAt: Int64?
    let reportedAt: Int64?
    let receivedAt: Int64?
    let expiresAt: Int64?
    let status: Status
    var id: HomeRoomMetric { metric }
}
struct HomeRoomStatus: Codable, Sendable {
    let apiVersion: Int
    let generatedAt: Int64
    let revision: Int64
    let config: HomeRoomConfiguration
    let connected: Bool
    let topic: String?
    let observations: [HomeRoomObservation]
    var version: HomeRoomVersion { .init(revision: revision, config: config) }
    static func validIdentifier(_ value: Int64) -> Bool { value > 0 && value <= 9_007_199_254_740_991 }
    static func timestamp(_ value: Int64) -> Bool { value > 0 && value <= 8_000_000_000_000 }
    static func issue(_ message: String = "The controller returned incompatible room data.") -> APIError { .serverError(message: message) }
    func validate() throws {
        guard apiVersion == 1, Self.timestamp(generatedAt), revision >= 0, revision < 9_007_199_254_740_991,
              try config.validated() == config, observations.count == config.mappings.count,
              Set(observations.map(\.metric)).count == observations.count else { throw Self.issue() }
        for item in observations {
            guard let mapping = config.mappings.first(where: { $0.metric == item.metric }), mapping.entityId == item.entityId,
                  item.unit == item.metric.unit, [item.measuredAt, item.reportedAt, item.receivedAt, item.expiresAt].allSatisfy({ $0.map(Self.timestamp) ?? true }),
                  [item.value, item.lastValue].allSatisfy({ $0.map { $0.isFinite && item.metric.range.contains($0) } ?? true }),
                  item.status == .fresh || item.value == nil else { throw Self.issue() }
            if item.status == .fresh {
                guard config.enabled, connected, item.value != nil, let measured = item.measuredAt, let reported = item.reportedAt,
                      let received = item.receivedAt, let expiry = item.expiresAt,
                      measured <= reported, reported <= received, received <= generatedAt,
                      expiry == measured + Int64(mapping.maxAgeSeconds * 1000), generatedAt < expiry else { throw Self.issue() }
            }
        }
    }
}
struct HomeRoomHistoryItem: Codable, Identifiable, Sendable {
    let id: Int64
    let revision: Int64
    let metric: HomeRoomMetric
    let entityId: String
    let unit: String
    let measuredAt: Int64?
    let reportedAt: Int64
    let receivedAt: Int64
    let value: Double?
    let available: Bool
}
struct HomeRoomHistory: Codable, Sendable {
    let apiVersion: Int
    let generatedAt: Int64
    let items: [HomeRoomHistoryItem]
    let nextBeforeId: Int64?
    func validate(before: Int64?) throws {
        guard apiVersion == 1, HomeRoomStatus.timestamp(generatedAt), items.count <= 200,
              Set(items.map(\.id)).count == items.count, items.map(\.id) == items.map(\.id).sorted(by: >),
              nextBeforeId == nil || nextBeforeId == items.last?.id else { throw HomeRoomStatus.issue() }
        for item in items {
            guard HomeRoomStatus.validIdentifier(item.id), HomeRoomStatus.validIdentifier(item.revision), before.map({ item.id < $0 }) ?? true,
                  item.unit == item.metric.unit, HomeRoomStatus.timestamp(item.reportedAt), HomeRoomStatus.timestamp(item.receivedAt),
                  item.measuredAt.map(HomeRoomStatus.timestamp) ?? true, item.reportedAt <= item.receivedAt, item.receivedAt <= generatedAt,
                  item.value.map({ $0.isFinite && item.metric.range.contains($0) }) ?? true,
                  item.available ? (item.value != nil && item.measuredAt != nil && item.measuredAt! <= item.reportedAt) : (item.value == nil && item.measuredAt == nil)
            else { throw HomeRoomStatus.issue() }
        }
    }
}
struct HomeRoomPublishers: Decodable, Sendable { let revision: Int64; let automations: [String] }
