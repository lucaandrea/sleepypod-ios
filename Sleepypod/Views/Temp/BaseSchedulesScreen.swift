import SwiftUI

struct BaseSchedulesScreen: View {
    @Bindable var model: BaseWorkspace
    @Environment(SettingsManager.self) private var settings
    private struct EditorDraft: Identifiable { let id = UUID(); let schedule: BaseSchedule }
    @State private var editing: EditorDraft?
    @State private var deleting: BaseSchedule?

    var body: some View {
        GroupedSection("BASE SCHEDULE") {
            VStack(alignment: .leading, spacing: 12) {
                Text(settings.timeZone).font(.mono(12)).foregroundStyle(Theme.text3)
                Text("Away mode pauses adjustments for that side. Both sides pause if either is away. Missed adjustments are skipped.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if !model.schedulesLoaded && model.scheduleError == nil { ProgressView("Loading schedules…") }
                if let error = model.scheduleError {
                    Text(error).font(.footnote).foregroundStyle(Theme.red)
                    Button("Reload schedules") { Task { await model.loadSchedules() } }.frame(minHeight: 44)
                }
                if model.schedulesLoaded && model.schedules.isEmpty {
                    Text("No scheduled positions yet.").font(.callout).foregroundStyle(Theme.text2)
                }
                ForEach(model.schedules) { schedule in
                    VStack(spacing: 8) {
                        HStack(alignment: .top) {
                            Button {
                                editing = EditorDraft(schedule: schedule)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(schedule.time) · \(schedule.presetName)").font(.callout.weight(.medium))
                                    Text("\(schedule.dayOfWeek.title) · \(name(schedule.side))").font(.caption).foregroundStyle(Theme.text2)
                                    Text("\(schedule.angles.label) · \(schedule.feedRate)%").font(.mono(12)).foregroundStyle(Theme.text3)
                                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("base.schedule.\(schedule.id ?? 0)")
                            Toggle("Enable \(schedule.presetName) at \(schedule.time)", isOn: Binding(get: { schedule.enabled }, set: { enabled in
                                var changed = schedule; changed.enabled = enabled
                                Task { await model.save(changed) }
                            })).labelsHidden().tint(Theme.green).disabled(model.savingSchedule)
                        }
                        HStack {
                            if !schedule.enabled { Text("Paused").font(.caption).foregroundStyle(Theme.text3) }
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = schedule }
                                .font(.caption).frame(minHeight: 44).disabled(model.savingSchedule)
                                .accessibilityLabel("Delete \(schedule.presetName) at \(schedule.time)")
                        }
                        Divider()
                    }
                }
                Button("Add adjustment", systemImage: "plus") {
                    editing = EditorDraft(schedule: BaseSchedule(feedRate: model.speed))
                }.frame(minHeight: 44).disabled(!model.schedulesLoaded || model.savingSchedule)
            }.cardStyle()
        }
        .sheet(item: $editing) { draft in
            BaseScheduleEditor(model: model, initial: draft.schedule)
        }
        .confirmationDialog("Delete scheduled adjustment?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting {
                Button("Delete adjustment", role: .destructive) { Task { await model.remove(deleting) }; self.deleting = nil }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            if let deleting { Text("\(deleting.dayOfWeek.title) at \(deleting.time) · \(deleting.presetName)") }
        }
    }
    private func name(_ side: BaseScope) -> String {
        side == .both ? "Both sides" : settings.sideName(for: side == .left ? .left : .right)
    }
}

private struct BaseScheduleEditor: View {
    @Bindable var model: BaseWorkspace
    @State private var draft: BaseSchedule
    @State private var attemptedSave = false
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    init(model: BaseWorkspace, initial: BaseSchedule) { self.model = model; _draft = State(initialValue: initial) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    GroupedCard {
                        field("Name") { TextField("Name", text: $draft.presetName).multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing).accessibilityLabel("Adjustment name") }
                        field("Days") {
                            Picker("Days", selection: $draft.dayOfWeek) {
                                ForEach(BaseScheduleDays.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityIdentifier("base.schedule.days")
                        }
                        field("Time") {
                            DatePicker("Time", selection: clock, displayedComponents: .hourAndMinute).labelsHidden()
                                .environment(\.timeZone, podTimeZone)
                        }
                        field("Sides") {
                            Picker("Schedule side", selection: $draft.side) {
                                ForEach(BaseScope.allCases.filter { model.independent || $0 == .both || $0 == draft.side }) { side in
                                    Text(side == .both ? "Both sides" : settings.sideName(for: side == .left ? .left : .right)).tag(side)
                                }
                            }.labelsHidden()
                        }
                        field("Enabled") { Toggle("Enabled", isOn: $draft.enabled).labelsHidden().tint(Theme.green) }
                    }
                    Text("Runs in \(settings.timeZone). Saving schedules future movement; it does not move the bed now.")
                        .font(.footnote).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading)
                    GroupedSection("POSITION") {
                        VStack(spacing: 18) {
                            Picker("Preset", selection: preset) {
                                Text("Custom").tag("custom")
                                ForEach(BasePreset.allCases) { Text($0.title).tag($0.rawValue) }
                            }.accessibilityIdentifier("base.schedule.preset")
                            BaseAngleControls(angles: Binding(get: { draft.angles }, set: { draft.head = Int($0.head); draft.feet = Int($0.feet) }))
                            BaseSpeedPicker(speed: $draft.feedRate)
                        }.cardStyle()
                    }
                    if let issue = model.validation(draft) {
                        Text(issue).font(.footnote).foregroundStyle(Theme.red).accessibilityIdentifier("base.schedule.validation")
                    }
                    if attemptedSave, let issue = model.scheduleError {
                        Text(issue).font(.footnote).foregroundStyle(Theme.red)
                    }
                }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
            }.background(Theme.background)
            .navigationTitle(draft.id == nil ? "New adjustment" : "Edit adjustment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.savingSchedule) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.savingSchedule ? "Saving…" : "Save") {
                        attemptedSave = true
                        Task { if await model.save(draft) { dismiss() } }
                    }.disabled(model.savingSchedule || model.validation(draft) != nil)
                }
            }
            .interactiveDismissDisabled(model.savingSchedule)
        }
    }
    @ViewBuilder private func field<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.callout).foregroundStyle(Theme.text2)
                control().frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true).padding(16)
        } else { SettingsRow(title, trailing: control) }
    }
    private var podTimeZone: TimeZone { TimeZone(identifier: settings.timeZone) ?? .current }
    private var clock: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = podTimeZone
            let parts = draft.time.split(separator: ":").compactMap { Int($0) }
            return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: parts.first ?? 22, minute: parts.last ?? 0)) ?? .now
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = podTimeZone
            draft.time = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        })
    }
    private var preset: Binding<String> {
        Binding(get: { BasePreset.allCases.first { $0.angles == draft.angles }?.rawValue ?? "custom" }, set: { value in
            guard let selected = BasePreset(rawValue: value) else { return }
            draft.head = Int(selected.angles.head); draft.feet = Int(selected.angles.feet); draft.presetName = selected.title
        })
    }
}
