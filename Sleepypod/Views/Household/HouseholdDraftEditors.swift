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
    @State private var initialized = false
    @State private var importReview: PersonalRoutineReview?
    @State private var clearWeek = false
    @State private var editingRevision: Int?
    @State private var reloadDraft = false
    private var savedDraftChanged: Bool { initialized && editingRevision != model.routines?.revision }
    var body: some View {
        Form {
            Section {
                Text("Draft only").font(.headline).foregroundStyle(Theme.amber).accessibilityIdentifier("household.routines.status")
                Text("Plan by bedtime night. Events after midnight belong to the following morning. These drafts do not run the bed or replace its current schedule.").font(.footnote)
            }
            Section("Bedtime nights") {
                ForEach(DayOfWeek.weekdays) { day in
                    NavigationLink {
                        HouseholdNightEditor(day: day, draft: binding(day), unit: model.draftPreferences.displayUnit,
                            hasRoutine: week.contains { $0.dayOfWeek == day }, remove: { week.removeAll { $0.dayOfWeek == day } })
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
            Section("Saved draft") {
                if savedDraftChanged {
                    Text("The saved draft changed while you were editing. Your local edits have been kept. Review the new saved values or explicitly keep your edits before saving.")
                        .font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("publication.editorConflict")
                    Button("Keep my edits for review") { editingRevision = model.routines?.revision }.disabled(!model.maySave)
                }
                Button("Reload saved draft") { reloadDraft = true }.disabled(!model.maySave)
                    .accessibilityIdentifier("publication.reloadDraft")
            }
            if let publication = model.publication, publication.enabled {
                Section("Start from your current week") {
                    Button("Copy current week into draft") {
                        Task { await publication.refresh(); importReview = publication.review }
                    }.disabled(!model.maySave || publication.refreshing || publication.publishing)
                        .accessibilityIdentifier("publication.copyCurrent")
                    Text("Reads your actual operating week. Confirm the copy, edit it, then save the draft. Copying never publishes it.").font(.footnote).foregroundStyle(Theme.text2)
                    if let error = publication.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                }
            }
            Section {
                Button("Clear draft week", role: .destructive) { clearWeek = true }.disabled(week.isEmpty || !model.maySave)
                    .accessibilityIdentifier("publication.clearDraft")
                Text("An empty draft removes all nights only after a separate review and publication.").font(.footnote).foregroundStyle(Theme.text2)
            }
            Section {
                Button("Save weekly drafts") {
                    do {
                        let normalized = week.map { HouseholdRoutine(dayOfWeek: $0.dayOfWeek, draft: $0.draft.normalized) }
                        try HouseholdRoutine.validate(normalized); validation = nil
                        Task {
                            await model.saveRoutines(normalized)
                            if model.pending == nil, model.routines?.routines == normalized,
                               PersonalRoutineWeek.normalized(week) == PersonalRoutineWeek.normalized(normalized) {
                                week = normalized; editingRevision = model.routines?.revision
                            }
                        }
                    } catch { validation = error.localizedDescription }
                }.disabled(!model.maySave || savedDraftChanged).accessibilityIdentifier("household.routines.save")
                if let validation { Text(validation).font(.footnote).foregroundStyle(Theme.amber) }
                HouseholdSaveFeedback()
            }
            if let publication = model.publication, publication.enabled {
                Section {
                    NavigationLink("Review saved draft for publication") { PersonalRoutineReviewScreen(model: publication, unit: model.draftPreferences.displayUnit) }
                        .disabled(!model.maySave || savedDraftChanged || PersonalRoutineWeek.normalized(week) != PersonalRoutineWeek.normalized(model.routines?.routines ?? []))
                        .accessibilityIdentifier("publication.openReview")
                    Text("Save your edits first. The review compares your saved draft with the current operating week.").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Weekly drafts")
            .onAppear { if !initialized { week = model.draftRoutines; editingRevision = model.routines?.revision; initialized = true } }
            .alert("Replace your edits with the saved draft?", isPresented: $reloadDraft) {
                Button("Load saved draft") {
                    if model.discardRetainedRoutineDraft() { week = model.routines?.routines ?? []; editingRevision = model.routines?.revision; validation = nil }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This discards unsaved changes in this editor, even when the saved draft revision has not changed. It does not publish anything.") }
            .alert("Replace this draft with your current week?", isPresented: Binding(get: { importReview != nil }, set: { if !$0 { importReview = nil } })) {
                Button("Copy current week") {
                    if let snapshot = importReview, model.publication?.review == snapshot,
                       let session = model.session, snapshot.scope.matches(session), model.maySave {
                        week = PersonalRoutineWeek.drafts(snapshot.liveWeek); validation = nil
                    }
                    importReview = nil
                }
                Button("Cancel", role: .cancel) { importReview = nil }
            } message: { Text("This replaces unsaved draft edits with the actual operating routines. It does not save or publish them.") }
            .alert("Clear every draft night?", isPresented: $clearWeek) {
                Button("Clear draft", role: .destructive) { week = []; validation = nil }
                Button("Cancel", role: .cancel) { }
            } message: { Text("The bed keeps its current week. Save the empty draft and review its removals separately before publication.") }
    }
    private func binding(_ day: DayOfWeek) -> Binding<BedtimeRoutineDraft> {
        Binding(get: { week.first { $0.dayOfWeek == day }?.draft ?? .blank }, set: { draft in
            if let index = week.firstIndex(where: { $0.dayOfWeek == day }) { week[index].draft = draft }
            else { week.append(.init(dayOfWeek: day, draft: draft)) }
        })
    }
}

private struct HouseholdNightEditor: View {
    @Environment(\.dismiss) private var dismiss
    let day: DayOfWeek
    @Binding var draft: BedtimeRoutineDraft
    let unit: String
    let hasRoutine: Bool
    let remove: () -> Void
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
            if hasRoutine {
                Section {
                    Button("Remove this draft night", role: .destructive) { remove(); dismiss() }
                    Text("The removal is a draft until the complete week is saved and separately published.").font(.footnote).foregroundStyle(Theme.text2)
                }
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
        Stepper("Snooze: \(PersonalRoutineWeek.duration(alarm.snoozeDuration ?? 300))", value: Binding(get: { alarm.snoozeDuration ?? 300 }, set: { alarm.snoozeDuration = $0 }), in: 60...1800, step: 60)
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
