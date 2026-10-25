import SwiftUI

struct RoutineClockField: View {
    let title: String
    @Binding var value: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sleepText(.small).foregroundStyle(SleepTheme.secondary)
            DatePicker(title, selection: Binding(get: { AlarmClock.date(value) }, set: { value = AlarmClock.time($0) }), displayedComponents: .hourAndMinute)
                .environment(\.timeZone, .gmt).labelsHidden().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SleepTheme.border(scheme)))
                .accessibilityLabel(title)
        }
    }
}
struct RoutineTemperatureField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let title: String
    @Binding var value: Int
    private var unit: String { model.settings?.temperatureFormat == "celsius" ? "C" : "F" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sleepText(.small).foregroundStyle(SleepTheme.secondary)
            Picker(title, selection: $value) {
                ForEach(55...110, id: \.self) { temperature in Text("\(model.temperatureLabel(Double(temperature)))°\(unit)").tag(temperature) }
            }.labelsHidden().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SleepTheme.border(scheme)))
                .accessibilityLabel(title)
        }
    }
}
struct RoutineNumberField: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let range: ClosedRange<Int>
    @Binding var value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sleepText(.small).foregroundStyle(SleepTheme.secondary)
            HStack {
                Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                    .disabled(value <= range.lowerBound).accessibilityLabel("Decrease \(title)")
                TextField(title, value: $value, format: .number.grouping(.never))
                    .keyboardType(.numberPad).multilineTextAlignment(.center).monospacedDigit()
                    .accessibilityLabel(title)
                Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .disabled(value >= range.upperBound).accessibilityLabel("Increase \(title)")
            }.buttonStyle(.plain).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SleepTheme.border(scheme)))
        }
    }
}
struct RoutinePowerFields: View {
    @Binding var schedule: DailySchedule
    var body: some View {
        SleepCard(title: "Your nightly routine", eyebrow: "POWER & TEMPERATURE") {
            Toggle("Enable routine", isOn: $schedule.power.enabled).tint(SleepTheme.accent)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { RoutineClockField(title: "Turn on", value: $schedule.power.on); RoutineClockField(title: "Turn off", value: $schedule.power.off) }
                VStack(spacing: 16) { RoutineClockField(title: "Turn on", value: $schedule.power.on); RoutineClockField(title: "Turn off", value: $schedule.power.off) }
            }
            RoutineTemperatureField(title: "Starting temperature", value: $schedule.power.onTemperature)
            Text("The selected day is the day your routine starts. Earlier clock times belong to the following day.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }
    }
}
struct RoutineAdjustmentFields: View {
    @Environment(AppModel.self) private var model
    @Binding var schedule: DailySchedule
    @State private var time = "01:00"
    @State private var temperature = 78
    @State private var editing: String?
    @State private var message: String?
    private var times: [String] {
        schedule.temperatures.keys.sorted { (RoutinePlan.offset($0, from: schedule.power.on) ?? -1) < (RoutinePlan.offset($1, from: schedule.power.on) ?? -1) }
    }
    var body: some View {
        SleepCard(title: "Through the night", eyebrow: "TEMPERATURE ADJUSTMENTS") {
            ForEach(times, id: \.self) { clock in
                HStack(spacing: 8) {
                    Text("\(clock) · \(model.temperatureLabel(Double(schedule.temperatures[clock] ?? 80)))°\(model.settings?.temperatureFormat == "celsius" ? "C" : "F")").sleepText(.body)
                    Spacer(minLength: 0)
                    Button("Edit") { editing = clock; time = clock; temperature = schedule.temperatures[clock] ?? 80; message = nil }
                        .accessibilityLabel("Edit adjustment \(clock)")
                    Button("Remove", role: .destructive) {
                        schedule.temperatures[clock] = nil; if editing == clock { editing = nil }
                    }.accessibilityLabel("Remove adjustment \(clock)")
                }.buttonStyle(SleepButtonStyle(kind: .text, horizontalPadding: 4))
            }
            if times.isEmpty { Text("Your starting temperature stays the same until turn-off.").foregroundStyle(SleepTheme.secondary) }
            RoutineClockField(title: "Adjustment time", value: $time)
            RoutineTemperatureField(title: "Target temperature", value: $temperature)
            HStack {
                Button(editing == nil ? "Add adjustment" : "Update adjustment", action: save).buttonStyle(SleepButtonStyle())
                if editing != nil { Button("Cancel edit") { editing = nil; message = nil } }
            }
            if let message { Text(message).foregroundStyle(SleepTheme.error).sleepText(.small) }
        }
    }
    private func save() {
        guard let offset = RoutinePlan.offset(time, from: schedule.power.on), offset > 0,
              let duration = RoutinePlan.offset(schedule.power.off, from: schedule.power.on), offset < duration else {
            message = "Choose a time between turn-on and turn-off."; return
        }
        guard editing == time || schedule.temperatures[time] == nil else {
            message = "An adjustment already uses this time. Edit that adjustment instead."; return
        }
        if let editing { schedule.temperatures[editing] = nil }
        schedule.temperatures[time] = temperature; editing = nil; message = nil
    }
}
struct RoutineAlarmFields: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var schedule: DailySchedule
    var test: () -> Void
    var body: some View {
        SleepCard(title: "Ease into the morning", eyebrow: "VIBRATION ALARM") {
            Toggle("Vibration alarm", isOn: $schedule.alarm.enabled).tint(SleepTheme.accent)
            if schedule.alarm.enabled {
                RoutineClockField(title: "Wake time", value: $schedule.alarm.time)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pattern").sleepText(.small).foregroundStyle(SleepTheme.secondary)
                    Picker("Pattern", selection: $schedule.alarm.vibrationPattern) { Text("Rise").tag("rise"); Text("Double").tag("double") }
                        .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SleepTheme.border(scheme)))
                        .accessibilityLabel("Pattern")
                }
                RoutineNumberField(title: "Intensity (%)", range: 1...100, value: $schedule.alarm.vibrationIntensity)
                RoutineNumberField(title: "Duration (seconds)", range: 1...180, value: $schedule.alarm.duration)
                Text("Vibration runs for at least 10 seconds and needs this side to be on. Add a temperature adjustment to warm before waking.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                Button("Test vibration", action: test).buttonStyle(SleepButtonStyle())
            }
        }
    }
}
