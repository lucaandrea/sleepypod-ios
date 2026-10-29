import SwiftUI

private struct RoutinePhaseEditSession: Identifiable {
    let id = UUID()
    let index: Int?
    let point: BedtimeRoutineDraft.Temperature
}
struct BedtimeRoutineEditor: View {
    let session: BedtimeRoutineEditSession
    let model: BedtimeRoutineWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @State private var draft: BedtimeRoutineDraft
    @State private var days: Set<DayOfWeek>
    @State private var phaseEditor: RoutinePhaseEditSession?
    @State private var reviewing = false
    init(session: BedtimeRoutineEditSession, model: BedtimeRoutineWorkspace) {
        self.session = session; self.model = model
        _draft = State(initialValue: session.book.routines.first { $0.dayOfWeek == session.day }?.draft ?? .blank)
        _days = State(initialValue: [session.day])
    }
    private var changes: BedtimeRoutineChanges {
        .init(side: session.book.side, changes: DayOfWeek.allCases.filter { days.contains($0) }.map { day in
            .init(dayOfWeek: day, expectedRevision: session.book.routines.first { $0.dayOfWeek == day }?.revision, replacement: draft.normalized)
        })
    }
    private var validation: String? {
        do { try changes.validate(against: session.book); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(session.day.displayName) night").font(.title3.bold())
                Text("Times follow \(settings.timeZone). After-midnight events run on the next calendar day.").font(.footnote).foregroundStyle(Theme.text2)
                if reviewing { review }
                else {
                    power
                    alarm
                    DisclosureGroup("Custom temperature phases (\(draft.temperatures.count))") { phases }
                    notes
                    nights
                }
                if let validation { Text(validation).font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("routine.validation") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("routine.editor.scroll").background(Theme.background).navigationTitle(reviewing ? "Review routine" : "Edit routine").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(reviewing ? "Back" : "Cancel") { if reviewing { reviewing = false } else { dismiss() } }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(reviewing ? "Save" : "Review") {
                        if reviewing { Task { if await model.save(changes) { await schedule.fetchSchedules(); dismiss() } } }
                        else { reviewing = true }
                    }.disabled(validation != nil || model.busy || model.requiresReload).accessibilityIdentifier("routine.commit")
                }
            }.interactiveDismissDisabled(model.busy)
            .sheet(item: $phaseEditor) { editing in
                NavigationStack {
                    RoutineTemperatureEditor(initial: editing.point) { point in
                        if let index = editing.index, draft.temperatures.indices.contains(index) { draft.temperatures[index] = point }
                        else { draft.temperatures.append(point) }
                        phaseEditor = nil
                    }
                }.tint(Theme.text1)
            }
    }
    private var power: some View {
        GroupedSection("POWER") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Routine active", isOn: $draft.power.enabled).tint(Theme.green).accessibilityIdentifier("routine.enabled")
                RoutineClockField("Bedtime", value: $draft.power.onTime)
                RoutineClockField("End time", value: $draft.power.offTime)
                RoutineTemperatureField("Overnight temperature", value: $draft.power.onTemperature)
                if draft.temperatures.contains(where: \.enabled) {
                    Text("This routine has later temperature changes. Changing the starting target does not remove them.").font(.footnote).foregroundStyle(Theme.amber)
                    Button("Hold this temperature all night") { draft.temperatures = [] }
                        .accessibilityIdentifier("routine.holdOvernight")
                } else {
                    Text("Holds this target until wake warming starts. Autopilot, if enabled, is governed by its separate comfort limits.").font(.footnote).foregroundStyle(Theme.text2)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("At the end").font(.headline)
                    Picker("At the end", selection: $draft.power.endAction) {
                        ForEach(ScheduleEndAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("routine.endAction")
                }
                Text("Pausing the routine also pauses its temperature phases and alarm. Saving does not immediately turn the bed on.").font(.footnote).foregroundStyle(Theme.text2)
            }.cardStyle()
        }
    }
    private var phases: some View {
        GroupedSection("TEMPERATURE PHASES") {
            VStack(alignment: .leading, spacing: 16) {
                if draft.temperatures.isEmpty { Text("No intermediate phases").foregroundStyle(Theme.text2) }
                ForEach(Array(draft.temperatures.enumerated()), id: \.offset) { index, point in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { phaseEditor = .init(index: index, point: point) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(DisplayTime.clock(point.time)).font(.headline)
                                Text(TemperatureDisplay.degrees.text(point.temperature, unit: settings.temperatureFormat, includeUnit: true) + (point.enabled ? "" : " · Paused"))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("routine.phase.\(index)")
                        Button("Remove phase", role: .destructive) { draft.temperatures.remove(at: index) }.font(.footnote).accessibilityIdentifier("routine.phase.remove.\(index)")
                    }
                    Divider()
                }
                Button("Add phase", systemImage: "plus") {
                    let start = BedtimeRoutineTime.minutes(draft.power.onTime) ?? 1320
                    let duration = BedtimeRoutineTime.offset(draft.power.offTime, from: draft.power.onTime)
                    let used = Set(draft.temperatures.map(\.time))
                    let offset = (1..<max(2, duration)).first { !used.contains(CurvePoint.clock(start + $0)) } ?? 1
                    let preferred = CurvePoint.clock(start + max(1, duration / 2))
                    let time = used.contains(preferred) ? CurvePoint.clock(start + offset) : preferred
                    phaseEditor = .init(index: nil, point: .init(time: time, temperature: draft.power.onTemperature, enabled: true))
                }.disabled(draft.temperatures.count >= 96).accessibilityIdentifier("routine.phase.add")
            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
        }
    }
    private var alarm: some View {
        GroupedSection("ALARM") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Include an alarm", isOn: Binding(get: { draft.alarm != nil }, set: { include in
                    draft.alarm = include ? .init(time: draft.power.offTime, vibrationIntensity: 50, vibrationPattern: .rise, duration: 10, alarmTemperature: draft.power.onTemperature, wakeWindow: 0, enabled: true, snoozeDuration: 300, snoozeTaper: 0) : nil
                })).tint(Theme.green).accessibilityIdentifier("routine.alarm.include")
                if draft.alarm != nil { RoutineAlarmFields(alarm: Binding(get: { draft.alarm ?? .standard }, set: { draft.alarm = $0 })) }
            }.cardStyle()
        }
    }
    private var notes: some View {
        GroupedSection("NOTES") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Routine notes", text: $draft.notes, axis: .vertical).lineLimit(2...8).accessibilityIdentifier("routine.notes")
                Text("\(draft.notes.utf16.count) / 1000").font(.caption).foregroundStyle(Theme.text2)
            }.cardStyle()
        }
    }
    private var nights: some View {
        GroupedSection("SAVE TO NIGHTS") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Copy this complete routine to additional nights. Existing routines on selected nights are replaced after review.").font(.footnote).foregroundStyle(Theme.text2)
                Button("Wake Monday–Friday") { days = [.sunday, .monday, .tuesday, .wednesday, .thursday] }
                    .accessibilityIdentifier("routine.weekdayWake")
                Text("Weekday mornings mean bedtime on Sunday–Thursday nights.").font(.footnote).foregroundStyle(Theme.text2)
                ForEach(DayOfWeek.weekdays) { day in
                    Toggle(day.displayName, isOn: Binding(get: { days.contains(day) }, set: { selected in
                        if selected { days.insert(day) } else { days.remove(day) }
                    })).tint(Theme.green).accessibilityIdentifier("routine.copy.\(day.rawValue)")
                }
            }.cardStyle()
        }
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review all selected nights").font(.headline)
            ForEach(DayOfWeek.weekdays.filter { days.contains($0) }) { day in
                VStack(alignment: .leading, spacing: 12) {
                    Text(day.displayName).font(.headline)
                    Text(session.book.routines.contains { $0.dayOfWeek == day } ? "Replaces the existing routine" : "Creates a new routine").font(.caption).foregroundStyle(Theme.text2)
                    BedtimeRoutineSummary(draft: draft.normalized, day: day, expanded: true)
                }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
            }
            Text("All selected nights save together. If any routine changed elsewhere, reload and review again.").font(.footnote).foregroundStyle(Theme.text2)
        }.accessibilityIdentifier("routine.review")
    }
}
