import Foundation

enum BedroomMetric: String, Codable, CaseIterable, Sendable {
    case temperature, humidity, pm25, co2, airQuality, power, fanSpeed, filterLife
    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .pm25: "Fine particles"
        case .co2: "Carbon dioxide"
        case .airQuality: "Air quality"
        case .power: "Power"
        case .fanSpeed: "Fan speed"
        case .filterLife: "Filter remaining"
        }
    }
    var unit: String {
        switch self {
        case .temperature: "°F"
        case .humidity, .fanSpeed, .filterLife: "%"
        case .pm25: "µg/m³"
        case .co2: "ppm"
        case .airQuality: "category"
        case .power: "on/off"
        }
    }
    func accepts(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        switch self {
        case .temperature: return (-40...140).contains(value)
        case .humidity, .fanSpeed, .filterLife: return (0...100).contains(value)
        case .pm25: return (0...2000).contains(value)
        case .co2: return (0...10000).contains(value)
        case .airQuality: return (1...5).contains(value) && value.rounded() == value
        case .power: return value == 0 || value == 1
        }
    }
}

struct BedroomSource: Codable, Equatable, Identifiable, Sendable {
    enum Provider: String, Codable, Sendable {
        case homeAssistant = "home_assistant", homebridge, appleHome = "apple_home"
        var title: String {
            switch self {
            case .homeAssistant: "Home Assistant"
            case .homebridge: "Homebridge"
            case .appleHome: "Apple Home"
            }
        }
    }
    enum Location: String, Codable, Sendable {
        case left, right, room
        var title: String {
            switch self {
            case .left: "Left bedside"
            case .right: "Right bedside"
            case .room: "Bedroom"
            }
        }
    }
    let id: String
    let deviceId: String
    let deviceName: String
    let label: String
    let provider: Provider
    let externalId: String
    let model: String
    let location: Location
    let metric: BedroomMetric
    let unit: String
    let maxAgeSeconds: Int
    var enabled: Bool
    var useForControl: Bool
}

struct BedroomConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var roomName: String
    var sources: [BedroomSource]
    static let empty = Self(enabled: false, roomName: "Bedroom", sources: [])
    func validate() throws {
        guard !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, roomName.utf16.count <= 60, sources.count <= 40,
              Set(sources.map(\.id)).count == sources.count,
              Set(sources.map { "\($0.deviceId)/\($0.metric.rawValue)" }).count == sources.count,
              Set(sources.map { "\($0.provider.rawValue)/\($0.externalId)" }).count == sources.count else { throw BedroomStatus.issue }
        for source in sources {
            let units = source.metric == .temperature ? ["°F", "°C"] : source.metric == .pm25 ? ["µg/m³", "μg/m³"] : [source.metric.unit]
            guard source.id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,119}$", options: .regularExpression) != nil,
                  source.deviceId.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,119}$", options: .regularExpression) != nil,
                  !source.deviceName.isEmpty, source.deviceName.utf16.count <= 80, !source.label.isEmpty, source.label.utf16.count <= 80,
                  !source.externalId.isEmpty, source.externalId.utf16.count <= 180, source.model.utf16.count <= 80,
                  (30...900).contains(source.maxAgeSeconds), units.contains(source.unit) else { throw BedroomStatus.issue }
        }
    }
}

struct BedroomVersion: Codable, Equatable, Sendable {
    let revision: Int64
    let config: BedroomConfiguration
}

struct BedroomObservation: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case disabled, waiting, unavailable, stale, cached, fresh
        var title: String {
            switch self {
            case .disabled: "Disabled"
            case .waiting: "Waiting for a report"
            case .unavailable: "Unavailable"
            case .stale: "Expired"
            case .cached: "Cached · not a live measurement"
            case .fresh: "Reporting"
            }
        }
    }
    enum TimeBasis: String, Codable, Sendable { case measurement, deviceRead = "device_read", integrationReport = "integration_report", cached }
    var id: String { source.id }
    let source: BedroomSource
    let status: State
    let value: Double?
    let lastValue: Double?
    let unit: String
    let observedAt: Int64?
    let measuredAt: Int64?
    let receivedAt: Int64?
    let expiresAt: Int64?
    let timeBasis: TimeBasis?
    let controlEligible: Bool
}

struct BedroomAggregate: Codable, Sendable {
    let metric: BedroomMetric
    let unit: String
    let value: Double?
    let status: String
    let sourceIds: [String]
    let spread: Double?
    let expiresAt: Int64?
}

struct BedroomGuidance: Codable, Sendable {
    let state: String
    let offsetF: Int
    let reason: String
    let sourceIds: [String]
    let expiresAt: Int64?
    let configuration: String?
    static let unavailable = Self(state: "unavailable", offsetF: 0, reason: "No qualified bedroom climate readings are available.", sourceIds: [], expiresAt: nil, configuration: nil)
}

struct BedroomStatus: Codable, Sendable {
    struct MQTT: Codable, Sendable { let connected: Bool; let topic: String? }
    let apiVersion: Int
    let generatedAt: Int64
    let revision: Int64
    let config: BedroomConfiguration
    let observations: [BedroomObservation]
    let aggregates: [BedroomAggregate]
    let guidance: BedroomGuidance
    let mqtt: MQTT?
    var version: BedroomVersion { .init(revision: revision, config: config) }
    static var issue: APIError { .serverError(message: "The bedroom sensor response is inconsistent. Refresh before using it.") }

    /// Validate source identities and clocks before any client treats a value as current.
    func validate() throws {
        try config.validate()
        guard apiVersion == 1, generatedAt > 0, generatedAt <= 8_000_000_000_000, revision >= 0,
              observations.count == config.sources.count, Set(observations.map(\.id)).count == observations.count,
              Set(aggregates.map(\.metric)).count == aggregates.count else { throw Self.issue }
        for item in observations {
            guard config.sources.contains(item.source), item.unit == item.source.metric.unit,
                  item.value.map(item.source.metric.accepts) ?? true,
                  item.lastValue.map(item.source.metric.accepts) ?? true,
                  [item.observedAt, item.measuredAt, item.receivedAt].allSatisfy({ timestamp in
                      guard let timestamp else { return true }
                      return timestamp > 0 && timestamp <= generatedAt
                  }) else { throw Self.issue }
            if item.status == .fresh {
                guard item.source.enabled, config.enabled, item.value != nil, let expires = item.expiresAt,
                      let observed = item.observedAt, let received = item.receivedAt, received >= observed,
                      expires > generatedAt, expires - generatedAt <= Int64(item.source.maxAgeSeconds * 1000),
                      item.timeBasis != nil, item.timeBasis != .cached,
                      item.timeBasis != .measurement || item.measuredAt != nil else { throw Self.issue }
                let reference = item.timeBasis == .measurement ? item.measuredAt! : observed
                guard reference <= observed, expires <= reference + Int64(item.source.maxAgeSeconds * 1000) else { throw Self.issue }
            }
            if item.controlEligible && (item.status != .fresh || !item.source.useForControl) { throw Self.issue }
        }
        for aggregate in aggregates {
            guard aggregate.unit == aggregate.metric.unit, aggregate.value.map(aggregate.metric.accepts) ?? true,
                  ["ready", "disagreement", "unavailable"].contains(aggregate.status),
                  Set(aggregate.sourceIds).count == aggregate.sourceIds.count else { throw Self.issue }
            if aggregate.status == "ready" {
                guard aggregate.value != nil, !aggregate.sourceIds.isEmpty, let expiry = aggregate.expiresAt, expiry > generatedAt,
                      aggregate.sourceIds.allSatisfy({ identifier in observations.contains { $0.id == identifier && $0.controlEligible && $0.source.metric == aggregate.metric && ($0.expiresAt ?? 0) >= expiry } }) else { throw Self.issue }
            }
        }
        guard ["ready", "unavailable", "disagreement"].contains(guidance.state), (-1...1).contains(guidance.offsetF) else { throw Self.issue }
        if guidance.state == "ready" {
            guard let expires = guidance.expiresAt, expires > generatedAt, expires - generatedAt <= 900_000,
                  guidance.configuration?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  !guidance.sourceIds.isEmpty,
                  guidance.sourceIds.allSatisfy({ identifier in observations.contains { $0.id == identifier && $0.controlEligible && ($0.expiresAt ?? 0) >= expires } }) else { throw Self.issue }
        }
    }
}
