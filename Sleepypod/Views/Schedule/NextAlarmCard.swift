import SwiftUI

struct NextAlarmCard: View {
    let side: Side
    var body: some View {
        if APIBackend.current == .freeSleep { WeeklyAlarmCard(side: side) }
        else { OccurrenceAlarmCard(side: side) }
    }
}
struct NativeNextAlarmScreen: View {
    let side: Side
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach([side] + Side.allCases.filter { $0 != side }) { current in NextAlarmCard(side: current) }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Next alarm").navigationBarTitleDisplayMode(.inline)
    }
}

private struct OccurrenceAlarmCard: View {
    let side: Side
    @Environment(AlarmWorkspace.self) private var weekly
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model = NextAlarmWorkspace()
    @State private var editing: AlarmDraft?
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    private var scope: String { "\(side.rawValue)|\(backend)|\(address)|\(host)|\(ownerRevision)" }
    private var group: AlarmGroup? {
        guard weekly.loaded else { return nil }
        if let ids = model.current?.alarm?.scheduleIds, let match = weekly.groups(side).first(where: { !$0.rows.filter { ids.contains($0.id) }.isEmpty }) { return match }
        return weekly.nextGroup(side, now: .now, timeZone: TimeZone(identifier: settings.timeZone) ?? .current)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("NEXT ALARM · \(settings.sideName(for: side).uppercased())")
            if APIBackend.current.isDemo, DebugRoute.nextAlarmScenario != "normal" { Text("SYNTHETIC ALARM EXAMPLE").font(.caption).foregroundStyle(Theme.amber) }
            if model.busy { ProgressView("Updating alarm…") }
            if let current = model.current { summary(current) }
            else if !model.busy { Text("Alarm status unavailable").foregroundStyle(Theme.text2) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("nextAlarm.error") }
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("nextAlarm.notice") }
            if let draft = model.draft { timeEditor(draft) }
            if weekly.loaded {
                Button(group == nil ? "Add alarm" : "Weekly schedule", systemImage: "calendar") {
                    editing = group.map(AlarmDraft.init(group:)) ?? AlarmDraft(sides: [side])
                }.disabled(model.busy || weekly.saving).accessibilityIdentifier("nextAlarm.weekly")
            }
            Button("Refresh saved alarm", systemImage: "arrow.clockwise") {
                Task { await weekly.refresh(); await model.load(userInitiated: true) }
            }.disabled(model.busy).accessibilityIdentifier("nextAlarm.reload")
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
            .task(id: scope) {
                model.configure(client: weekly.occurrenceClient(timeZone: settings.timeZone, scenario: DebugRoute.nextAlarmScenario), side: side)
                await weekly.refresh(); await model.load()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if phase == .active { await model.load() }
                }
            }
            .onChange(of: phase) { if phase == .active { Task { await model.load() } } else { model.invalidate() } }
            .onDisappear { model.invalidate() }
            .sheet(item: $editing, onDismiss: { Task { await weekly.refresh(); await schedule.fetchSchedules(); await model.load(userInitiated: true) } }) { NativeAlarmEditor(initial: $0) }
    }
    @ViewBuilder private func summary(_ current: NextAlarmState) -> some View {
        if let alarm = current.alarm {
            Text(DisplayTime.clock(alarm.time)).font(.mono(26, relativeTo: .title2))
            if current.state == "skipped" { Label("Skipped once", systemImage: "bell.slash").foregroundStyle(Theme.amber).accessibilityIdentifier("nextAlarm.skipped") }
            Text("\(current.label(alarm.at)) · \(alarm.duration.formatted())s vibration · \(current.timeZone)").font(.footnote).foregroundStyle(Theme.text2)
            if current.state == "skipped", let following = current.followingAt {
                Text("Following routine alarm: \(current.label(following))").font(.footnote).accessibilityIdentifier("nextAlarm.following")
            }
            Text("Wake temperature \(TemperatureConversion.displayTemp(Int(alarm.alarmTemperatureF.rounded()), format: settings.temperatureFormat.degreeUnit)) · \(alarm.wakeWindow.formatted()) min wake window")
                .font(.caption).foregroundStyle(Theme.text2)
        } else { Text(current.state == "away" ? "This side is away" : "No alarm set").foregroundStyle(Theme.text2) }
        if !current.reason.isEmpty { Text(current.reason).font(.footnote).foregroundStyle(Theme.text2) }
        if let execution = current.execution { Text("Command \(execution). Physical vibration has not been verified.").font(.footnote).foregroundStyle(Theme.amber) }
        if let change = current.change {
            Text(change.status == "active" ? "One-time change expires \(current.label(change.expiresAt))." : "The temporary change is \(change.status). Current weekly routines apply.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
        if current.alarm != nil {
            if current.state != "skipped" {
                Button("Skip this alarm", systemImage: "bell.slash") { Task { _ = await model.skip() } }
                    .disabled(!model.canChange || model.draft != nil).accessibilityIdentifier("nextAlarm.skip")
            }
            Button("Change this time", systemImage: "clock") { model.beginTime() }
                .disabled(!model.canChange || model.draft != nil).accessibilityIdentifier("nextAlarm.change")
        }
        if current.change != nil {
            Button(current.alarm == nil ? "Clear expired change" : "Restore routine alarm", systemImage: "arrow.uturn.backward") { Task { _ = await model.restore() } }
                .disabled(model.busy || model.requiresReload || model.draft != nil).accessibilityIdentifier("nextAlarm.restore")
        }
    }
    private func timeEditor(_ draft: NextAlarmWorkspace.Draft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("This alarm only").font(.headline)
            if typeSize.isAccessibilitySize {
                Text("Wake time")
                wakeTimePicker(draft).labelsHidden()
            } else { wakeTimePicker(draft) }
            Text("Same wake date: \(draft.base.alarm.map { draft.base.label($0.originalAt) } ?? "Unavailable"). Warm-up and the movement wake window follow this time. Weekly routines stay saved.")
                .font(.footnote).foregroundStyle(Theme.text2)
            if model.changedDraft { Text("The saved alarm changed. Your draft is retained; cancel and review the new alarm before editing it.").font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("nextAlarm.changedDraft") }
            Button("Save one-time alarm") { Task { _ = await model.saveTime() } }.disabled(!model.canSaveDraft).accessibilityIdentifier("nextAlarm.save")
            Button("Cancel time change") { model.cancelTime() }.disabled(model.busy).accessibilityIdentifier("nextAlarm.cancel")
        }
    }
    private func wakeTimePicker(_ draft: NextAlarmWorkspace.Draft) -> some View {
        DatePicker("Wake time", selection: clock(draft), displayedComponents: .hourAndMinute)
            .environment(\.timeZone, TimeZone(identifier: draft.base.timeZone) ?? .gmt)
            .environment(\.calendar, Calendar(identifier: .gregorian)).disabled(model.busy).accessibilityIdentifier("nextAlarm.time")
    }
    private func clock(_ draft: NextAlarmWorkspace.Draft) -> Binding<Date> {
        Binding(get: {
            // Use a neutral date for the time-only control; Core validates the actual wake date and DST.
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: draft.base.timeZone) ?? .gmt
            let minutes = AlarmDraft.clockMinutes(model.draft?.time ?? draft.time) ?? 420
            return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: minutes / 60, minute: minutes % 60)) ?? .now
        }, set: { model.editTime(NextAlarmState.clock($0, timeZone: draft.base.timeZone)) })
    }
}
