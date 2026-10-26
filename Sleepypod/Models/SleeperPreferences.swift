import Foundation

struct BedSetupPreferences: Codable, Sendable, Equatable {
    var bedMode: String
    var unusedZoneMode: String
    let timezone: String
    let timeFormat: String
    var fields: [String: SettingsFieldValue] { ["bedMode": .string(bedMode), "unusedZoneMode": .string(unusedZoneMode)] }
    var issue: String? {
        ["two", "solo-left", "solo-right"].contains(bedMode) && ["off", "follow", "independent"].contains(unusedZoneMode)
            ? nil : "Reload to read a supported bed setup."
    }
}

struct SleeperPreferences: Codable, Sendable, Equatable {
    let side: Side
    var name: String
    var awayMode: Bool
    var awayStart: String?
    var awayReturn: String?
    var alwaysOn: Bool
    var autoOffEnabled: Bool
    var autoOffMinutes: Int
    var autoOnEnabled: Bool
    var autoOnMinutes: Int
    var autoOnStart: String
    var autoOnEnd: String
    var fields: [String: SettingsFieldValue] {
        ["name": .string(name), "awayMode": .boolean(awayMode), "awayStart": awayStart.map(SettingsFieldValue.string) ?? .null,
         "awayReturn": awayReturn.map(SettingsFieldValue.string) ?? .null, "alwaysOn": .boolean(alwaysOn),
         "autoOffEnabled": .boolean(autoOffEnabled), "autoOffMinutes": .integer(autoOffMinutes),
         "autoOnEnabled": .boolean(autoOnEnabled), "autoOnMinutes": .integer(autoOnMinutes),
         "autoOnStart": .string(autoOnStart), "autoOnEnd": .string(autoOnEnd)]
    }
    var issue: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 20 else { return "Names must be 1–20 characters." }
        guard !(alwaysOn && autoOffEnabled) else { return "Always on and presence auto-off cannot both be enabled." }
        guard (5...120).contains(autoOffMinutes), (1...60).contains(autoOnMinutes) else { return "Choose 5–120 minutes for auto-off and 1–60 minutes for auto-on." }
        guard DevicePreferences.validClock(autoOnStart), DevicePreferences.validClock(autoOnEnd) else { return "Choose valid auto-on window times." }
        guard [awayStart, awayReturn].allSatisfy({ $0.map { SensorObservation.date($0) != nil } ?? true }) else { return "The away dates could not be read. Reload before editing." }
        if let start = awayStart.flatMap(SensorObservation.date), let end = awayReturn.flatMap(SensorObservation.date), end < start { return "Return must be after the saved away start." }
        return nil
    }
    // Pair the mutually exclusive flags in one request, including an unchanged false value.
    func patch(from saved: Self) -> SettingsFieldPatch {
        var changes = fields.filter { saved.fields[$0.key] != $0.value }
        if alwaysOn && !saved.alwaysOn { changes["autoOffEnabled"] = .boolean(false) }
        if autoOffEnabled && !saved.autoOffEnabled { changes["alwaysOn"] = .boolean(false) }
        return .init(fields: changes)
    }
    func merging(_ patch: SettingsFieldPatch) throws -> Self {
        var values = fields; values.merge(patch.fields) { _, next in next }; values["side"] = .string(side.rawValue)
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(values))
    }
    static func demo(_ side: Side) -> Self {
        .init(side: side, name: side == .left ? "Alex" : "Sam", awayMode: false, alwaysOn: false, autoOffEnabled: false, autoOffMinutes: 30, autoOnEnabled: false, autoOnMinutes: 5, autoOnStart: "20:00", autoOnEnd: "08:00")
    }
}

struct SleeperPreferencesSnapshot: Codable, Sendable, Equatable {
    struct Sides: Codable, Sendable, Equatable {
        var left: SleeperPreferences
        var right: SleeperPreferences
        subscript(_ side: Side) -> SleeperPreferences {
            get { side == .left ? left : right }
            set { if side == .left { left = newValue } else { right = newValue } }
        }
    }
    var device: BedSetupPreferences
    var sides: Sides
    static let demo = Self(device: .init(bedMode: "two", unusedZoneMode: "off", timezone: "America/Los_Angeles", timeFormat: "12h"), sides: .init(left: .demo(.left), right: .demo(.right)))
}
