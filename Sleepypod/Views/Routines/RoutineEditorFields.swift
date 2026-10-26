import SwiftUI

struct RoutineClockField: View {
    let title: String
    @Binding var value: String
    init(_ title: String, value: Binding<String>) { self.title = title; _value = value }
    // A fixed date avoids DST resolving a plain recurring HH:mm into a different wall-clock time.
    private var clock: Binding<Date> {
        Binding(get: {
            let minutes = BedtimeRoutineTime.minutes(value) ?? 0
            return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: minutes / 60, minute: minutes % 60))!
        }, set: { date in
            value = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        })
    }
    private var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            DatePicker(title, selection: clock, displayedComponents: .hourAndMinute).labelsHidden()
                .environment(\.timeZone, calendar.timeZone).accessibilityIdentifier("routine.clock.\(title)")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct RoutineTemperatureField: View {
    let title: String
    @Binding var value: Int
    @Environment(SettingsManager.self) private var settings
    init(_ title: String, value: Binding<Int>) { self.title = title; _value = value }
    private var label: String { TemperatureDisplay.degrees.text(value, unit: settings.temperatureFormat, includeUnit: true) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(label).font(.mono(25, relativeTo: .title2)).foregroundStyle(TempColor.forScheduled(value))
            Stepper(title, onIncrement: { adjust(1) }, onDecrement: { adjust(-1) }).labelsHidden().accessibilityLabel(title).accessibilityValue(label)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func adjust(_ direction: Int) { value = min(110, max(55, TemperatureDisplay.degrees.step(value, by: direction, unit: settings.temperatureFormat))) }
}
struct RoutineTemperatureEditor: View {
    @State private var point: BedtimeRoutineDraft.Temperature
    let save: (BedtimeRoutineDraft.Temperature) -> Void
    @Environment(\.dismiss) private var dismiss
    init(initial: BedtimeRoutineDraft.Temperature, save: @escaping (BedtimeRoutineDraft.Temperature) -> Void) { _point = State(initialValue: initial); self.save = save }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RoutineClockField("Phase time", value: $point.time)
                RoutineTemperatureField("Phase temperature", value: $point.temperature)
                Toggle("Phase active", isOn: $point.enabled).tint(Theme.green)
                Text("Changes remain in the local routine draft until you review and save the complete routine.").font(.footnote).foregroundStyle(Theme.text2)
            }.frame(maxWidth: 780, alignment: .leading).padding(20).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Temperature phase").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(point) }.accessibilityIdentifier("routine.phase.done") }
            }
    }
}
struct RoutineAlarmFields: View {
    @Binding var alarm: BedtimeRoutineDraft.Alarm
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Alarm active", isOn: $alarm.enabled).tint(Theme.green)
            RoutineClockField("Wake time", value: $alarm.time)
            RoutineTemperatureField("Wake temperature", value: $alarm.alarmTemperature)
            Picker("Pattern", selection: $alarm.vibrationPattern) { Text("Rise").tag(VibrationPattern.rise); Text("Double").tag(VibrationPattern.double) }.pickerStyle(.segmented)
            RoutineNumberField("Intensity", value: $alarm.vibrationIntensity, range: 1...100, suffix: "%")
            RoutineNumberField("Vibration duration", value: $alarm.duration, range: 10...180, suffix: " sec")
            VStack(alignment: .leading, spacing: 8) {
                Text("Wake window").font(.headline)
                Picker("Wake window", selection: $alarm.wakeWindow) {
                    Text("Exact time").tag(0)
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }.pickerStyle(.menu).labelsHidden()
            }
            RoutineNumberField("Snooze duration", value: Binding(get: { alarm.snoozeDuration ?? 300 }, set: { alarm.snoozeDuration = $0 }), range: 60...1800, step: 60, suffix: " sec", identifier: "routine.alarm.snooze")
            VStack(alignment: .leading, spacing: 8) {
                Text("Snooze duration reduction").font(.headline)
                Picker("Snooze duration reduction", selection: Binding(get: { alarm.snoozeTaper ?? 0 }, set: { alarm.snoozeTaper = $0 })) {
                    Text("None").tag(0); ForEach([30, 40, 50, 60], id: \.self) { Text("\($0)%").tag($0) }
                }.pickerStyle(.menu).labelsHidden()
            }
            Text("An alarm at the end time keeps thermal power on through the vibration and for fifteen minutes afterward. Pod 5 covers ignore pattern and intensity.").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
}

/// Keep the value above its controls so long accessibility text never squeezes the stepper.
private struct RoutineNumberField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int
    let suffix: String
    let identifier: String
    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, suffix: String, identifier: String = "") {
        self.title = title; _value = value; self.range = range; self.step = step; self.suffix = suffix; self.identifier = identifier
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text("\(value)\(suffix)").font(.mono(23, relativeTo: .title3))
            Stepper(title, value: $value, in: range, step: step).labelsHidden().accessibilityLabel(title)
                .accessibilityValue("\(value)\(suffix)").accessibilityIdentifier(identifier)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
