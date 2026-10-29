import SwiftUI

struct HouseholdPreferencesEditor: View {
    @Environment(HouseholdWorkspace.self) private var model
    @State private var draft = HouseholdPreferences.blank
    var body: some View {
        Form {
            Section("Personal comfort") {
                Picker("Display unit", selection: $draft.displayUnit) { Text("°F").tag("F"); Text("°C").tag("C") }
                PersonalTemperatureField("Preferred temperature", value: $draft.preferredTemperatureF, unit: draft.displayUnit)
                Picker("How you sleep", selection: $draft.comfort) {
                    Text("Warm sleeper").tag("warm_sleeper"); Text("Balanced").tag("balanced"); Text("Cold sleeper").tag("cold_sleeper")
                }
                Toggle("Share my wake time", isOn: $draft.shareWakeTime)
                Text("Only these personal preferences are saved. Cloud analysis stays off. These values do not change the current bed temperature.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            Section {
                Button("Save preferences") { Task { await model.savePreferences(draft) } }.disabled(!model.maySave)
                    .accessibilityIdentifier("household.preferences.save")
                HouseholdSaveFeedback()
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Comfort preferences")
            .onAppear { draft = model.draftPreferences }
    }
}

struct HouseholdRoutineWeek: View {
    @Environment(HouseholdWorkspace.self) private var model
    @State private var week: [HouseholdRoutine] = []
    @State private var validation: String?
    var body: some View {
        Form {
            Section {
                Text("Draft only").font(.headline).foregroundStyle(Theme.amber).accessibilityIdentifier("household.routines.status")
                Text("Plan by bedtime night. Events after midnight belong to the following morning. These drafts do not run the bed or replace its current schedule.").font(.footnote)
            }
            Section("Bedtime nights") {
                ForEach(DayOfWeek.weekdays) { day in
                    NavigationLink {
                        HouseholdNightEditor(day: day, draft: binding(day), unit: model.draftPreferences.displayUnit)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(day.displayName)
                            if let draft = week.first(where: { $0.dayOfWeek == day })?.draft {
                                Text("\(draft.power.onTime)–\(draft.power.offTime) · \(draft.power.enabled ? "Enabled in draft" : "Paused in draft")")
                                    .font(.caption).foregroundStyle(Theme.text2)
                            } else { Text("No draft").font(.caption).foregroundStyle(Theme.text2) }
                        }
                    }.accessibilityIdentifier("household.night.\(day.rawValue)")
                }
                Text("Weekday morning alarms belong to Sunday–Thursday nights.").font(.footnote).foregroundStyle(Theme.text2)
            }
            Section {
                Button("Save weekly drafts") {
                    do {
                        let normalized = week.map { HouseholdRoutine(dayOfWeek: $0.dayOfWeek, draft: $0.draft.normalized) }
                        try HouseholdRoutine.validate(normalized); validation = nil
                        Task { await model.saveRoutines(normalized) }
                    } catch { validation = error.localizedDescription }
                }.disabled(!model.maySave).accessibilityIdentifier("household.routines.save")
                if let validation { Text(validation).font(.footnote).foregroundStyle(Theme.amber) }
                HouseholdSaveFeedback()
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Weekly drafts")
            .onAppear { if week.isEmpty { week = model.draftRoutines } }
    }
    private func binding(_ day: DayOfWeek) -> Binding<BedtimeRoutineDraft> {
        Binding(get: { week.first { $0.dayOfWeek == day }?.draft ?? .blank }, set: { draft in
            if let index = week.firstIndex(where: { $0.dayOfWeek == day }) { week[index].draft = draft }
            else { week.append(.init(dayOfWeek: day, draft: draft)) }
        })
    }
}

private struct HouseholdNightEditor: View {
    let day: DayOfWeek
    @Binding var draft: BedtimeRoutineDraft
    let unit: String
    var body: some View {
        Form {
            Section("Power · draft only") {
                Toggle("Enabled in draft", isOn: $draft.power.enabled)
                RoutineClockField("Bedtime", value: $draft.power.onTime)
                RoutineClockField("End time", value: $draft.power.offTime)
                PersonalTemperatureField("Overnight temperature", value: $draft.power.onTemperature, unit: unit)
                Picker("At the end", selection: $draft.power.endAction) {
                    ForEach(ScheduleEndAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Temperature phases") {
                ForEach(draft.temperatures.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        RoutineClockField("Phase time", value: $draft.temperatures[index].time)
                        PersonalTemperatureField("Phase temperature", value: $draft.temperatures[index].temperature, unit: unit)
                        Toggle("Phase enabled in draft", isOn: $draft.temperatures[index].enabled)
                        Button("Remove phase", role: .destructive) { draft.temperatures.remove(at: index) }
                    }
                }
                Button("Add phase") {
                    let start = BedtimeRoutineTime.minutes(draft.power.onTime) ?? 1320
                    let duration = BedtimeRoutineTime.offset(draft.power.offTime, from: draft.power.onTime)
                    let used = Set(draft.temperatures.map(\.time))
                    let offset = (1..<max(2, duration)).first { !used.contains(CurvePoint.clock(start + $0)) } ?? 1
                    draft.temperatures.append(.init(time: CurvePoint.clock(start + offset), temperature: draft.power.onTemperature, enabled: true))
                }.disabled(draft.temperatures.count >= 96)
            }
            Section("Wake alarm · draft only") {
                Toggle("Include an alarm", isOn: Binding(get: { draft.alarm != nil }, set: { draft.alarm = $0 ? .standard : nil }))
                if draft.alarm != nil { HouseholdAlarmDraft(alarm: Binding(get: { draft.alarm ?? .standard }, set: { draft.alarm = $0 }), unit: unit) }
            }
            Section("Private notes") {
                TextField("Routine notes", text: $draft.notes, axis: .vertical).lineLimit(2...8)
                Text("\(draft.notes.utf16.count) / 1000").font(.caption).foregroundStyle(Theme.text2)
                Text("Return to Weekly drafts to save all nights together. Nothing here activates an alarm.").font(.footnote).foregroundStyle(Theme.amber)
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("\(day.displayName) draft").navigationBarTitleDisplayMode(.inline)
    }
}

private struct HouseholdAlarmDraft: View {
    @Binding var alarm: BedtimeRoutineDraft.Alarm
    let unit: String
    var body: some View {
        Toggle("Alarm enabled in draft", isOn: $alarm.enabled)
        RoutineClockField("Wake time", value: $alarm.time)
        PersonalTemperatureField("Wake temperature", value: $alarm.alarmTemperature, unit: unit)
        Stepper("Duration: \(alarm.duration) seconds", value: $alarm.duration, in: 10...180, step: 10)
        Stepper("Intensity: \(alarm.vibrationIntensity)%", value: $alarm.vibrationIntensity, in: 1...100)
        Picker("Pattern", selection: $alarm.vibrationPattern) { Text("Rise").tag(VibrationPattern.rise); Text("Double").tag(VibrationPattern.double) }
        Picker("Wake window", selection: $alarm.wakeWindow) {
            Text("Exact time").tag(0); ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) minutes").tag($0) }
        }
        Stepper("Snooze: \((alarm.snoozeDuration ?? 300) / 60) minutes", value: Binding(get: { alarm.snoozeDuration ?? 300 }, set: { alarm.snoozeDuration = $0 }), in: 60...1800, step: 60)
        Picker("Snooze reduction", selection: Binding(get: { alarm.snoozeTaper ?? 0 }, set: { alarm.snoozeTaper = $0 })) {
            Text("None").tag(0); ForEach([30, 40, 50, 60], id: \.self) { Text("\($0)%").tag($0) }
        }
    }
}

private struct PersonalTemperatureField: View {
    let title: String
    @Binding var value: Int
    let unit: String
    init(_ title: String, value: Binding<Int>, unit: String) { self.title = title; _value = value; self.unit = unit }
    var body: some View {
        Stepper(value: $value, in: 55...110) {
            VStack(alignment: .leading) {
                Text(title)
                Text(unit == "C" ? String(format: "%.1f °C", Double(value - 32) * 5 / 9) : "\(value) °F")
                    .font(.title3.monospacedDigit()).foregroundStyle(TempColor.forScheduled(value))
            }
        }
    }
}

private struct HouseholdSaveFeedback: View {
    @Environment(HouseholdWorkspace.self) private var model
    var body: some View {
        if model.busy { ProgressView("Saving…") }
        if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
        if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
        if model.pending != nil || model.needsDraftReview {
            Text("Return to Personal account to resolve the saved request or review newer values.").font(.footnote).foregroundStyle(Theme.amber)
        }
    }
}
