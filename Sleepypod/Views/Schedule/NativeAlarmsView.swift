import SwiftUI

struct NativeAlarmsScreen: View {
    let sides: SideSelection
    var body: some View {
        ScrollView { NativeAlarmsSection(sides: sides).frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity) }
            .background(Theme.background).navigationTitle("Alarms")
    }
}

struct NativeAlarmsSection: View {
    let sides: SideSelection
    @Environment(AlarmWorkspace.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @State private var editing: AlarmDraft?
    @State private var deleting: AlarmGroup?

    var body: some View {
        VStack(spacing: 16) {
            ForEach(sides.sides) { side in
                GroupedSection(sides == .both ? "\(settings.sideName(for: side).uppercased()) · ALARMS" : "ALARMS") {
                    VStack(spacing: 12) {
                        if model.loading && !model.loaded { ProgressView("Loading alarms…") }
                        if !model.loaded && !model.rows.isEmpty { Text("Saved alarm details · reload to confirm current settings").font(.footnote).foregroundStyle(Theme.amber) }
                        if model.loaded && model.groups(side).isEmpty { Text("No alarms set").font(.callout).foregroundStyle(Theme.text2) }
                        ForEach(model.groups(side)) { group in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "alarm").foregroundStyle(group.alarm.enabled ? Theme.amber : Theme.text3).padding(.top, 4)
                                Button { editing = AlarmDraft(group: group) } label: {
                                    AlarmSummary(group: group).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!model.loaded || model.saving).accessibilityIdentifier("alarm.edit.\(group.id)")
                                Toggle("Alarm at \(group.alarm.time) enabled", isOn: Binding(get: { group.alarm.enabled }, set: { enabled in
                                    Task { await model.toggle(group, enabled: enabled); await schedule.fetchSchedules() }
                                })).labelsHidden().tint(Theme.green).disabled(model.saving || !model.loaded)
                            }
                            HStack {
                                Button("Test", systemImage: "play") { Task { await model.test(AlarmDraft(group: group)) } }
                                    .disabled(!model.loaded || model.testing || model.stopping).accessibilityLabel("Test alarm at \(group.alarm.time)")
                                Spacer()
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = group }
                                    .disabled(model.saving || !model.loaded).accessibilityLabel("Delete alarm at \(group.alarm.time)")
                            }.font(.footnote).frame(minHeight: 44)
                            Divider()
                        }
                        Button("Add alarm", systemImage: "plus") { editing = AlarmDraft(sides: Set(sides == .both ? Side.allCases : [side])) }
                            .frame(minHeight: 44).disabled(!model.loaded || model.saving).accessibilityIdentifier("alarm.add.\(side.rawValue)")
                    }.cardStyle()
                }
            }
            AlarmFeedback()
        }
        .task { await model.refresh() }
        .sheet(item: $editing) { draft in NativeAlarmEditor(initial: draft) }
        .confirmationDialog("Delete this alarm?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let group = deleting {
                Button("Delete alarm", role: .destructive) { Task { _ = await model.delete(group); await schedule.fetchSchedules() }; deleting = nil }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            if let group = deleting { Text("\(settings.sideName(for: group.alarm.side)) · \(group.daysLabel) at \(DisplayTime.clock(group.alarm.time))") }
        }
    }
}

private struct AlarmSummary: View {
    let group: AlarmGroup
    @Environment(SettingsManager.self) private var settings
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(DisplayTime.clock(group.alarm.time)).font(.mono(21, relativeTo: .title3)).foregroundStyle(Theme.text1)
            Text(group.daysLabel + (group.alarm.enabled ? "" : " · Paused")).font(.footnote).foregroundStyle(Theme.text2)
            Text("\(group.alarm.duration)s buzz · \(TemperatureConversion.displayTemp(Int(group.alarm.alarmTemperature.rounded()), format: settings.temperatureFormat.degreeUnit))")
                .font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text3)
            if let window = group.alarm.wakeWindow, window > 0 {
                Text("\(window) min wake window").font(.caption).foregroundStyle(Theme.amber)
            }
            if let duration = group.alarm.snoozeDuration {
                Text("\((Double(duration) / 60).formatted(.number.precision(.fractionLength(0...1)))) min snooze" + ((group.alarm.snoozeTaper ?? 0) > 0 ? " · \(group.alarm.snoozeTaper!)% taper" : ""))
                    .font(.caption).foregroundStyle(Theme.text3)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private struct AlarmFeedback: View {
    var context = "list"
    @Environment(AlarmWorkspace.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.demo { Text("DEMO · alarms and vibration tests are simulated").font(.caption).foregroundStyle(Theme.text3) }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(Theme.red)
                Button("Reload alarms") { Task { await model.refresh() } }.frame(minHeight: 44).disabled(model.loading || model.saving)
            }
            if let error = model.commandError { Text(error).font(.footnote).foregroundStyle(Theme.red) }
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            if !model.testingSides.isEmpty {
                Button("Stop vibration test", systemImage: "stop.fill", role: .destructive) { Task { await model.stopTest() } }
                    .frame(minHeight: 44).disabled(model.stopping).accessibilityIdentifier("alarm.test.stop.\(context)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeAlarmEditor: View {
    @State private var draft: AlarmDraft
    @Environment(AlarmWorkspace.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    init(initial: AlarmDraft) { _draft = State(initialValue: initial) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    GroupedCard {
                        field("Wake at") {
                            DatePicker("Wake at", selection: clock, displayedComponents: .hourAndMinute).labelsHidden().environment(\.timeZone, timeZone)
                        }
                        field("Enabled") { Toggle("Alarm enabled", isOn: $draft.enabled).labelsHidden().tint(Theme.green) }
                        field("Side") {
                            Picker("Alarm side", selection: sideSelection) {
                                Text(settings.leftName).tag(SideSelection.left)
                                Text(settings.rightName).tag(SideSelection.right)
                                Text("Both").tag(SideSelection.both)
                            }.labelsHidden().accessibilityIdentifier("alarm.side")
                        }
                    }
                    GroupedSection("REPEAT") {
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack { quickPick("Weekdays", Array(DayOfWeek.weekdays.prefix(5))); quickPick("Weekends", [.saturday, .sunday]); quickPick("Every day", DayOfWeek.allCases) }
                                VStack(alignment: .leading) { quickPick("Weekdays", Array(DayOfWeek.weekdays.prefix(5))); quickPick("Weekends", [.saturday, .sunday]); quickPick("Every day", DayOfWeek.allCases) }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 76))], spacing: 8) {
                                ForEach(DayOfWeek.weekdays) { day in
                                    Button { if draft.days.contains(day) { draft.days.remove(day) } else { draft.days.insert(day) } } label: {
                                        Text(String(day.displayName.prefix(3))).frame(maxWidth: .infinity, minHeight: 44)
                                            .background(draft.days.contains(day) ? Theme.text1 : Theme.background, in: RoundedRectangle(cornerRadius: 12))
                                            .foregroundStyle(draft.days.contains(day) ? Theme.background : Theme.text2)
                                    }.buttonStyle(.plain).accessibilityLabel(day.displayName).accessibilityValue(draft.days.contains(day) ? "Selected" : "Not selected")
                                }
                            }
                            Text(settings.timeZone).font(.caption).foregroundStyle(Theme.text3)
                        }.cardStyle()
                    }
                    GroupedSection("WAKE WINDOW") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Wake window", selection: $draft.wakeWindow) {
                                ForEach(AlarmDraft.wakeWindows, id: \.self) { Text($0 == 0 ? "Off" : "\($0) min").tag($0) }
                            }.pickerStyle(.menu).accessibilityIdentifier("alarm.wakeWindow")
                            Text(draft.wakeWindow == 0 ? "Goes off at the set time." : "Wakes you the first time you move after \(DisplayTime.clock(draft.windowStart)), up to \(draft.wakeWindow) minutes early. Otherwise it goes off at \(DisplayTime.clock(draft.time)).")
                                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    if model.supportsSnooze {
                        GroupedSection("SNOOZE") {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Snooze for \((Double(draft.snoozeDuration) / 60).formatted(.number.precision(.fractionLength(0...1)))) min").font(.callout)
                                Stepper("Snooze length", value: $draft.snoozeDuration, in: 60...1800, step: 60).labelsHidden()
                                    .accessibilityLabel("Snooze length").accessibilityValue("\(draft.snoozeDuration) seconds")
                                Text("Snooze taper").font(.callout).foregroundStyle(Theme.text2)
                                Picker("Snooze taper", selection: $draft.snoozeTaper) {
                                    ForEach(AlarmDraft.snoozeTapers, id: \.self) { Text($0 == 0 ? "Off" : "\($0)%").tag($0) }
                                }.pickerStyle(.menu).accessibilityIdentifier("alarm.snoozeTaper")
                                Text(draft.snoozeTaper == 0 ? "Every snooze has the same length." : "Each snooze is \(draft.snoozeTaper)% shorter: \(draft.snoozePreview)…")
                                    .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                        }
                    }
                    GroupedSection("VIBRATION") {
                        VStack(alignment: .leading, spacing: 16) {
                            Picker("Pattern", selection: $draft.pattern) { Text("Rise").tag(VibrationPattern.rise); Text("Double").tag(VibrationPattern.double) }
                                .pickerStyle(.menu)
                            Text("Intensity · \(draft.intensity)%").font(.callout)
                            Slider(value: Binding(get: { Double(draft.intensity) }, set: { draft.intensity = Int($0.rounded()) }), in: 1...100, step: 1) { Text("Vibration intensity") }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Duration · \(draft.duration)s").font(.callout)
                                Stepper("Vibration duration", value: $draft.duration, in: 0...180, step: 10).labelsHidden().accessibilityLabel("Vibration duration").accessibilityValue("\(draft.duration) seconds")
                            }
                            Text("Pod 5 covers ignore pattern and intensity; duration changes the vibration you feel.").font(.footnote).foregroundStyle(Theme.text3)
                            Button("Test vibration", systemImage: "play") { Task { await model.test(draft) } }
                                .frame(minHeight: 44).disabled(!model.loaded || model.testing || model.stopping)
                        }.cardStyle()
                    }
                    GroupedSection("TEMPERATURE AT WAKE") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(TemperatureConversion.displayTemp(draft.temperature, format: settings.temperatureFormat.degreeUnit)).font(.mono(28, relativeTo: .title))
                            Stepper("Wake temperature", onIncrement: { adjustTemperature(1) }, onDecrement: { adjustTemperature(-1) })
                                .labelsHidden().accessibilityLabel("Wake temperature").accessibilityValue(TemperatureConversion.displayTemp(draft.temperature, format: settings.temperatureFormat.degreeUnit))
                        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    if let validation = draft.validation { Text(validation).font(.footnote).foregroundStyle(Theme.amber) }
                    AlarmFeedback(context: "editor")
                }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
            }.background(Theme.background).navigationTitle(draft.original.isEmpty ? "New alarm" : "Edit alarm").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.saving ? "Saving…" : "Save") {
                        Task { if await model.save(draft) { await schedule.fetchSchedules(); dismiss() } }
                    }.disabled(model.saving || !model.loaded || draft.validation != nil)
                }
            }.interactiveDismissDisabled(model.saving)
        }
    }
    private var timeZone: TimeZone { TimeZone(identifier: settings.timeZone) ?? .current }
    private var clock: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            let minutes = AlarmDraft.clockMinutes(draft.time) ?? 420
            return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: minutes / 60, minute: minutes % 60)) ?? .now
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            draft.time = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        })
    }
    private var sideSelection: Binding<SideSelection> {
        Binding(get: { draft.sides.count == 2 ? .both : draft.sides.contains(.right) ? .right : .left }, set: { draft.sides = Set($0.sides) })
    }
    private func quickPick(_ title: String, _ days: [DayOfWeek]) -> some View {
        Button(title) { draft.days = Set(days) }.buttonStyle(.bordered).accessibilityAddTraits(draft.days == Set(days) ? .isSelected : [])
    }
    private func adjustTemperature(_ direction: Int) {
        draft.temperature = TemperatureDisplay.degrees.step(draft.temperature, by: direction, unit: settings.temperatureFormat.degreeUnit)
    }
    @ViewBuilder private func field<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) { Text(title).font(.callout).foregroundStyle(Theme.text2); control() }
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(16)
        } else { SettingsRow(title, trailing: control) }
    }
}

struct NextAlarmCard: View {
    let side: Side
    @Environment(AlarmWorkspace.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @State private var editing: AlarmDraft?
    @State private var pinnedIDs: Set<Int> = []
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let group = nextGroup(at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("NEXT ALARM · \(settings.sideName(for: side).uppercased())")
                if let group {
                    HStack(alignment: .top) {
                        Button { editing = AlarmDraft(group: group) } label: { AlarmSummary(group: group).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("Edit next alarm at \(group.alarm.time)")
                        Toggle("Next alarm enabled", isOn: Binding(get: { group.alarm.enabled }, set: { enabled in
                            pinnedIDs = Set(group.rows.map(\.id))
                            Task { await model.toggle(group, enabled: enabled); await schedule.fetchSchedules() }
                        })).labelsHidden().fixedSize().tint(Theme.green).disabled(model.saving || !model.loaded)
                    }
                } else if model.loading { ProgressView("Loading alarms…") }
                else if model.loaded { Button("Add alarm", systemImage: "plus") { editing = AlarmDraft(sides: [side]) }.frame(minHeight: 44) }
                if !model.loaded && !model.loading { Text("Alarm status unavailable").font(.callout).foregroundStyle(Theme.text2) }
                AlarmFeedback()
            }.cardStyle()
        }
        .task(id: side) { pinnedIDs = []; await model.refresh() }
        .sheet(item: $editing) { NativeAlarmEditor(initial: $0) }
    }
    private func nextGroup(at date: Date) -> AlarmGroup? {
        guard model.loaded else { return nil }
        if let pinned = model.groups(side).first(where: { !pinnedIDs.isDisjoint(with: Set($0.rows.map(\.id))) }) { return pinned }
        return model.nextGroup(side, now: date, timeZone: TimeZone(identifier: settings.timeZone) ?? .current)
    }

}
