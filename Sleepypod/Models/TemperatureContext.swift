import Foundation

/// Stored environment values are requested in Celsius, independent of the control scale.
struct RoomSnapshot: Decodable, Sendable {
    let timestamp: String
    let ambientTemp: Double?
    let humidity: Double?
    let leftOuterTemp: Double?
    let leftCenterTemp: Double?
    let leftInnerTemp: Double?
    let rightOuterTemp: Double?
    let rightCenterTemp: Double?
    let rightInnerTemp: Double?

    var date: Date? { ReferenceDate.parse(timestamp) }
    func bedAir(side: Side) -> Double? {
        let values = side == .left ? [leftOuterTemp, leftCenterTemp, leftInnerTemp] : [rightOuterTemp, rightCenterTemp, rightInnerTemp]
        let present = values.compactMap { $0 }.filter(\.isFinite)
        return present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)
    }
    static func isFresh(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return (-5..<120).contains(now.timeIntervalSince(date))
    }
}

struct LightSnapshot: Decodable, Sendable {
    let timestamp: String
    let lux: Double?
    var date: Date? { ReferenceDate.parse(timestamp) }
}

struct RecentSleepVitals: Decodable, Sendable {
    struct Provenance: Decodable, Sendable {
        let configurationCount: Int
        let unknownConfigurationRows: Int
        let hrvMetricId: String?
        let hrvAggregation: String
    }
    let avgHeartRate: Double?
    let avgHRV: Double?
    let avgBreathingRate: Double?
    let recordCount: Int
    var provenance: Provenance?

    var comparableHRV: Double? {
        guard provenance?.hrvAggregation != "incompatible_definitions" else { return nil }
        return avgHRV
    }
    var note: String {
        guard let provenance else { return "Pod readings · processing details unavailable" }
        if provenance.hrvAggregation == "incompatible_definitions" { return "Pod readings · HRV omitted because its definitions differ" }
        if provenance.configurationCount > 1 { return "Pod readings · multiple processing configurations" }
        if provenance.unknownConfigurationRows > 0 { return "Pod readings · includes unverified processing history" }
        return "Pod readings · \(provenance.hrvMetricId.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "no HRV readings")"
    }
}

struct TemperatureContextValue<Value: Sendable>: Sendable {
    var value: Value?
    var error: String?

    static func capture(_ fetch: @Sendable () async throws -> Value?) async -> Self {
        do { return Self(value: try await fetch()) }
        catch { return Self(error: error.localizedDescription) }
    }
}

struct RecentSleepContext: Sendable {
    let record: SleepRecord
    let vitals: TemperatureContextValue<RecentSleepVitals>
}

struct TemperatureContextResult: Sendable {
    let room: TemperatureContextValue<RoomSnapshot>
    let light: TemperatureContextValue<LightSnapshot>
    let sleep: TemperatureContextValue<RecentSleepContext>
}

struct SleepNavigationRequest: Identifiable {
    let id = UUID()
    let record: SleepRecord
}

extension Notification.Name {
    static let showSleepRecord = Notification.Name("showSleepRecord")
}
