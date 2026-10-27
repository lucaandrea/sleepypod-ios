import Foundation

/// Compatibility settings edits carry their original snapshot so unrelated fields stay untouched.
struct SettingsChanges: Sendable {
    let device: SettingsFieldPatch
    let left: SettingsFieldPatch
    let right: SettingsFieldPatch
    let originalDevice: [String: SettingsFieldValue]
    let originalLeft: [String: SettingsFieldValue]
    let originalRight: [String: SettingsFieldValue]
    init(desired: PodSettings, original: PodSettings) {
        let originalDevice = Self.deviceFields(original)
        let originalLeft = Self.sideFields(original.left)
        let originalRight = Self.sideFields(original.right)
        self.originalDevice = originalDevice; self.originalLeft = originalLeft; self.originalRight = originalRight
        var deviceFields = Self.deviceFields(desired).filter { originalDevice[$0.key] != $0.value }
        // Older settings projections supply fallback times for nulls; enabling must persist that displayed time.
        if desired.rebootDaily && !original.rebootDaily, let time = desired.rebootTime { deviceFields["rebootTime"] = .string(time) }
        if desired.primePodDaily.enabled && !original.primePodDaily.enabled { deviceFields["primePodTime"] = .string(desired.primePodDaily.time) }
        device = .init(fields: deviceFields)
        left = .init(fields: Self.sideFields(desired.left).filter { originalLeft[$0.key] != $0.value })
        right = .init(fields: Self.sideFields(desired.right).filter { originalRight[$0.key] != $0.value })
    }
    var isEmpty: Bool { device.isEmpty && left.isEmpty && right.isEmpty }
    func conflicts(with current: PodSettings) -> Bool {
        device.conflicts(original: originalDevice, current: Self.deviceFields(current)) ||
        left.conflicts(original: originalLeft, current: Self.sideFields(current.left)) ||
        right.conflicts(original: originalRight, current: Self.sideFields(current.right))
    }
    func isReflected(in current: PodSettings) -> Bool {
        let reportedDevice = Self.deviceFields(current)
        let reportedLeft = Self.sideFields(current.left)
        let reportedRight = Self.sideFields(current.right)
        return device.fields.allSatisfy { reportedDevice[$0.key] == $0.value } &&
            left.fields.allSatisfy { reportedLeft[$0.key] == $0.value } &&
            right.fields.allSatisfy { reportedRight[$0.key] == $0.value }
    }
    private static func deviceFields(_ value: PodSettings) -> [String: SettingsFieldValue] {
        var fields: [String: SettingsFieldValue] = [
            "timezone": .string(value.timeZone), "temperatureUnit": .string(value.temperatureFormat.degreeUnit == .celsius ? "C" : "F"),
            "rebootDaily": .boolean(value.rebootDaily), "rebootTime": value.rebootTime.map(SettingsFieldValue.string) ?? .null,
            "primePodDaily": .boolean(value.primePodDaily.enabled), "primePodTime": .string(value.primePodDaily.time)
        ]
        if let action = value.defaultScheduleEndAction { fields["defaultScheduleEndAction"] = .string(action.rawValue) }
        return fields
    }
    private static func sideFields(_ value: SideSettings) -> [String: SettingsFieldValue] { ["name": .string(value.name), "awayMode": .boolean(value.awayMode)] }
}
