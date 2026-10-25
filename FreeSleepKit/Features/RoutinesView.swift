import SwiftUI

struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("podURL") private var address = ""
    @State private var loadedPod: String?
    @State private var book: RoutineBook?
    @State private var busy = false
    @State private var reloadVersion = 0
    @State private var loadError: String?
    @State private var status: (key: String, text: String, error: Bool)?
    @State private var dialog: RoutineDialog?
    private var workspace: RoutineWorkspace { model.routineWorkspace }
    private var pod: String { model.demo ? "demo" : address + "|" + (model.settings?.id ?? "") }
    private var prefix: String { "\(pod)|\(model.side.rawValue)|" }
    private var key: String { prefix + workspace.day }
    private var original: DailySchedule? { loadedPod == pod ? book?[model.side.rawValue]?[workspace.day] : nil }
    private var draft: RoutineDraft? { workspace.drafts[key] }
    private var selected: DailySchedule? { original == nil ? nil : draft?.value ?? original }
    private var copies: Set<String> { draft?.copies ?? [] }
    private var scheduleBinding: Binding<DailySchedule> {
        Binding(get: { selected ?? .empty }, set: { mutate($0) })
    }
    var body: some View {
        @Bindable var workspace = workspace
        SleepPage(title: "Set your rhythm.", subtitle: "A comfortable night, right on time.", narrow: true) {
            SidePicker().disabled(busy)
            if typeSize.isAccessibilitySize {
                Picker("Routine day", selection: $workspace.day) {
                    ForEach(RoutinePlan.days, id: \.self) { Text($0.capitalized).tag($0) }
                }.disabled(busy)
            } else {
                SleepSegmentedPicker(title: "Routine day", options: RoutinePlan.days, selection: $workspace.day) { day in
                    String(day.capitalized.prefix(3)) + (workspace.drafts[prefix + day] == nil ? "" : " ·")
                }.disabled(busy)
            }
            if let loadError {
                Text(loadError).foregroundStyle(SleepTheme.error)
                Button("Retry") { Task { await load() } }.buttonStyle(SleepButtonStyle())
            } else if let selected {
                editor(selected)
            } else { ProgressView("Loading routines…") }
        }.task(id: pod) { loadedPod = nil; book = nil; dialog = nil; await load() }
            .confirmationDialog(dialog?.title ?? "", isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }), titleVisibility: .visible) {
                if let dialog {
                    Button(dialog.action == .test ? "Test now" : "Reload saved", role: dialog.action == .reload ? .destructive : nil) { Task { await confirm(dialog) } }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                if let dialog {
                    Text(dialog.action == .test
                         ? "Vibrate the \(model.side.rawValue) side for 10 seconds now, including when the routine is off. Requires a local Pod connection."
                         : "Discard \(workspace.day.capitalized)'s draft and copy selections, then load the saved routine.")
                }
            }
    }
    @ViewBuilder private func editor(_ selected: DailySchedule) -> some View {
        let problems = RoutinePlan.problems(selected)
        SleepCard(title: "\(workspace.day.capitalized) night", eyebrow: "POD LOCAL TIME · \(model.settings?.timeZone ?? "Unknown")",
                  badge: draft != nil ? "Unsaved" : selected.power.enabled ? "Enabled" : "Off") {
            RoutineTimeline(schedule: selected)
        }
        if model.settings?[model.side].awayMode == true { Text("Away mode is on. This side's routines are paused.").foregroundStyle(SleepTheme.info) }
        Group {
            RoutinePowerFields(schedule: scheduleBinding)
            RoutineAdjustmentFields(schedule: scheduleBinding).id("\(key)|\(reloadVersion)")
            RoutineAlarmFields(schedule: scheduleBinding) { dialog = .init(key: key, action: .test) }
            RoutineCopyFields(day: workspace.day, copies: Binding(get: { copies }, set: { mutate(selected, copyDays: $0) }))
        }.disabled(busy)
        ForEach(problems, id: \.self) { Text($0).sleepText(.small).foregroundStyle(SleepTheme.error) }
        if let status, status.key == key {
            Text(status.text).sleepText(.small).foregroundStyle(status.error ? SleepTheme.error : SleepTheme.success)
                .accessibilityLabel(status.text)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { saveActions(problems) }
            VStack(alignment: .leading, spacing: 8) { saveActions(problems) }
        }
        Text("Drafts stay per side and day while this app is open. Changes take effect only after saving.")
            .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
    }
    @ViewBuilder private func saveActions(_ problems: [String]) -> some View {
        Button(busy ? "Saving…" : copies.isEmpty ? "Save routine" : "Save \(copies.count + 1) days") { Task { await save() } }
            .buttonStyle(SleepButtonStyle(kind: .primary)).disabled(busy || draft == nil || !problems.isEmpty)
        Button("Reload saved") { dialog = .init(key: key, action: .reload) }.buttonStyle(SleepButtonStyle()).disabled(busy)
    }
    private func mutate(_ value: DailySchedule, copyDays: Set<String>? = nil) {
        guard let original else { return }
        workspace.put(key, original: original, value: value, copies: copyDays ?? copies); status = nil
    }
    @discardableResult private func load() async -> Bool {
        let scope = pod
        loadError = nil
        do {
            let result: RoutineBook
            if model.demo {
                guard let demo = workspace.demoBook else { throw PodError.message("The demo routines could not be loaded.") }
                result = demo
            } else { result = try await PodClient.configured().get("schedules") }
            guard !Task.isCancelled, scope == pod else { return false }
            guard RoutinePlan.hasCompleteWeek(result) else { throw PodError.message("The server returned an incomplete week.") }
            book = result; loadedPod = scope
            return true
        } catch {
            if !Task.isCancelled, scope == pod { loadError = "Unable to load routines. Your drafts are still here. " + error.localizedDescription }
            return false
        }
    }
    private func save() async {
        guard let selected, let original, let book else { return }
        let scope = key; let savedPod = pod; let side = model.side; let day = workspace.day
        let days = [day] + RoutinePlan.days.filter { copies.contains($0) }
        if let occupied = copies.first(where: { workspace.drafts[prefix + $0] != nil }) {
            status = (scope, "Save or reset \(occupied.capitalized)'s draft before copying to it.", true); return
        }
        var expected: [String: DailySchedule] = [:]
        for target in days { expected[target] = target == day ? draft?.original ?? original : book[side.rawValue]?[target] }
        let request = RoutineSave(side: side, days: days, schedule: selected, expected: expected)
        let keys = days.map { prefix + $0 }
        busy = true; defer { busy = false }
        do {
            let result: RoutineBook
            if model.demo { result = try workspace.saveDemo(request) }
            else { result = try await PodClient.configured().postReturning("schedules/routine", body: request) }
            if savedPod == pod { self.book = result; loadedPod = savedPod }; workspace.clear(keys)
            status = (scope, "Saved \(days.map(\.capitalized).joined(separator: ", ")) for the \(side.rawValue) side.", false)
        } catch { status = (scope, error.localizedDescription, true) }
    }
    private func confirm(_ request: RoutineDialog) async {
        guard request.key == key, let selected else { return }
        busy = true; defer { busy = false }
        do {
            if request.action == .reload {
                guard await load() else { return }
                workspace.clear([request.key]); reloadVersion += 1; status = (request.key, "Saved routine reloaded.", false)
            } else {
                struct TestAlarm: Encodable { var side: BedSide; var duration = 10; var vibrationIntensity: Int; var vibrationPattern: String; var force = true }
                if !model.demo { try await PodClient.configured().post("alarm", body: TestAlarm(side: model.side, vibrationIntensity: selected.alarm.vibrationIntensity, vibrationPattern: selected.alarm.vibrationPattern)) }
                status = (request.key, "Vibration test command sent for 10 seconds.", false)
            }
        } catch { status = (request.key, error.localizedDescription, true) }
    }
}
private struct RoutineDialog {
    enum Action { case reload, test }
    var key: String
    var action: Action
    var title: String { action == .test ? "Test vibration?" : "Reload saved routine?" }
}
