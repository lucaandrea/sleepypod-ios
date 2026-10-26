import SwiftUI

struct CalendarScheduleControls: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ScheduleManager.self) private var schedules
    @Environment(SettingsManager.self) private var settings
    @Environment(AlarmWorkspace.self) private var alarms
    @State private var model = CalendarScheduleWorkspace()
    @State private var review: CalendarScheduleControl?
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var ownerURL = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    private var sides: [Side] { schedules.selectedSide.sides }
    private var scope: String { "\(backend)|\(ownerURL)|\(host)|\(ownerRevision)|\(schedules.revision)|\(sides.map(\.rawValue).joined(separator: ","))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("ALL SCHEDULES")
            ForEach(sides) { side in
                if let rows = model.rows[side] {
                    Toggle(settings.sideName(for: side), isOn: Binding(get: { CalendarScheduleControl.isEnabled(rows) }, set: { review = .init(side: side, original: rows, enabled: $0) }))
                        .tint(Theme.green).accessibilityIdentifier("schedule.global.\(side.rawValue)")
                        .disabled(model.saving || model.loading || !CalendarScheduleControl.hasRows(rows))
                    Text("\(rows.temperature.count) temperature points · \(rows.power.count) power windows · \(rows.alarm.count) alarms")
                        .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                } else if model.loading { ProgressView("Loading \(settings.sideName(for: side))…") }
                if let error = model.errors[side] { Text("\(settings.sideName(for: side)): \(error)").font(.footnote).foregroundStyle(Theme.amber) }
            }
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            if !model.errors.isEmpty { Button("Reload all schedules") { Task { await model.load(sides) } }.disabled(model.saving || model.loading) }
            Text("Applies to every day, including alarms. It keeps each saved time and temperature.").font(.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }.cardStyle()
        .task(id: scope) {
            let client: (any CalendarScheduleClient)? = APIBackend.current.isDemo
                ? DemoCalendarScheduleClient(api: APIBackend.current.createClient())
                : (try? CoreRESTClient.configured()).map { CoreCalendarScheduleClient(transport: $0) }
            review = nil; model.configure(client: client); await model.load(sides)
        }
        .onDisappear { model.invalidate(); review = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.invalidate(); review = nil }
            else { Task { await model.load(sides) } }
        }
        .confirmationDialog(review.map { "\($0.enabled ? "Enable" : "Pause") all schedules?" } ?? "All schedules", isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }), titleVisibility: .visible) {
            if let pending = review {
                Button(pending.enabled ? "Enable all schedules" : "Pause all schedules") {
                    Task {
                        if await model.apply(pending) { await schedules.fetchSchedules(); await alarms.refresh() }
                    }
                }
            }
        } message: {
            if let pending = review {
                Text(pending.enabled ? "Also enables paused alarms and other schedules for \(settings.sideName(for: pending.side))." : "Applies to \(settings.sideName(for: pending.side)) on all seven days, including alarms.")
            }
        }
    }
}
