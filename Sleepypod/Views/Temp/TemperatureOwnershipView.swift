import SwiftUI

struct TemperatureOwnershipView: View {
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        @Bindable var device = device
        if APIBackend.current != .freeSleep {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(device.isLinked ? Side.allCases : device.selectedSide.sides) { side in
                    if let control = device.deviceStatus?.temperatureControl?[side] {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.isLinked ? "\(settings.sideName(for: side)) · \(control.title)" : control.title)
                                if let date = control.holdDate { Text("Until \(clock(date))").foregroundStyle(Theme.text2) }
                            }.font(.mono(12, relativeTo: .caption))
                            Spacer(minLength: 8)
                            if control.holdUntil != nil {
                                Button("Resume") { device.resumeTemperature(side: side) }
                                    .disabled(device.isSendingMutation || device.controlsBlocked(for: side))
                            }
                        }.foregroundStyle(control.blocked == "safety" ? Theme.red : Theme.text2)
                    }
                }
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
                layout {
                    Text("Hold after adjustment").font(.subheadline).foregroundStyle(Theme.text2)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Picker("Temperature hold duration", selection: $device.holdMinutes) {
                        ForEach(TemperatureHold.options) { Text($0.title).tag($0.minutes) }
                    }.labelsHidden().pickerStyle(.menu).tint(Theme.text1)
                }
            }.padding(.horizontal, 4)
        }
    }
    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: settings.timeZone)
        return formatter.string(from: date)
    }
}

struct TemperatureNoticesView: View {
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        VStack(spacing: 8) {
            if let error = device.commandError {
                notice("Command failed", detail: error, icon: "exclamationmark.circle", color: Theme.red) {
                    Button("Dismiss") { device.commandError = nil }
                }
            }
            ForEach(Side.allCases) { side in
                if let stall = device.deviceStatus?.pumpStallNotifications?[side] {
                    notice("\(settings.sideName(for: side)) · Pump stopped", detail: "Pump RPM fell to \(Int(stall.rpm)). This side is off for safety.", icon: "exclamationmark.triangle", color: Theme.red) {
                        Button("Re-enable") { device.resolvePumpStall(side: side, restore: true) }
                        Button("Dismiss") { device.resolvePumpStall(side: side, restore: false) }
                    }
                }
            }
            if device.deviceStatus?.isPriming == true {
                notice("Priming", detail: "Temperature controls resume when it finishes.", icon: "drop", color: Theme.cool) { EmptyView() }
            } else if let completion = device.deviceStatus?.primeCompletedNotification {
                let seconds = completion.timestamp > 1e12 ? completion.timestamp / 1000 : completion.timestamp
                if Date().timeIntervalSince1970 - seconds < 3600 {
                    notice("Priming complete", detail: "Your Pod is ready.", icon: "checkmark.circle", color: Theme.green) {
                        Button("Dismiss") { device.dismissPrimeCompletion() }
                    }
                }
            }
            if device.isAlarmActive {
                notice("Alarm active", detail: "\(alarmNames) vibrating", icon: "alarm", color: Theme.amber) {
                    Button("Snooze 5 min") { device.snoozeAlarm() }
                    Button("Stop") { device.stopAlarm() }
                }
            } else if !snoozedSides.isEmpty {
                notice("Alarm snoozed", detail: snoozedSides.map { settings.sideName(for: $0) }.joined(separator: " & "), icon: "clock", color: Theme.amber) {
                    Button("Cancel snooze") { device.stopAlarm() }
                }
            }
        }
        .padding(.horizontal, 16)
    }
    private var alarmNames: String {
        Side.allCases.filter { device.deviceStatus?.status(for: $0).isAlarmVibrating == true }
            .map { settings.sideName(for: $0) }.joined(separator: " & ")
    }
    private var snoozedSides: [Side] { Side.allCases.filter { device.deviceStatus?.snooze?[$0]?.active == true } }
    private func notice<Actions: View>(_ title: String, detail: String, icon: String, color: Color, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            Text(detail).font(.footnote).foregroundStyle(Theme.text2)
            HStack(spacing: 20) { actions() }.font(.subheadline.weight(.semibold)).disabled(device.isSendingMutation)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle(vertical: 12)
    }
}
