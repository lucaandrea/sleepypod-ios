import SwiftUI
import FreeSleepKit

struct BedtimeRoutinesDestination: View {
    let side: Side
    var body: some View {
        if APIBackend.current == .freeSleep { PodFeatureScreen(.routines, side: side.rawValue) }
        else { BedtimeRoutinesScreen(side: side) }
    }
}
struct BedtimeRoutineEditSession: Identifiable {
    let id = UUID()
    let day: DayOfWeek
    let book: BedtimeRoutineBook
}
struct BedtimeRoutinesScreen: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @Environment(\.scenePhase) private var phase
    @State private var model = BedtimeRoutineWorkspace()
    @State private var demoClient = DemoBedtimeRoutineClient()
    @State private var side: Side
    @State private var editor: BedtimeRoutineEditSession?
    @State private var deleting: BedtimeRoutineSnapshot?
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    init(side: Side) { _side = State(initialValue: side) }
    private var scope: String { "\(backend)|\(address)|\(host)|\(ownerRevision)|\(side.rawValue)|\(phase)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Routine side", selection: $side) { ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) } }
                    .pickerStyle(.segmented).disabled(model.busy).accessibilityIdentifier("routines.side")
                if APIBackend.current.isDemo { Eyebrow("DEMO · LOCAL DRAFTS", color: Theme.amber) }
                Text("Each night includes power, temperature phases and an optional alarm. Morning events belong to the night before.").font(.footnote).foregroundStyle(Theme.text2)
                Text("Times follow your Pod: \(settings.timeZone)").font(.caption).foregroundStyle(Theme.text2)
                if model.busy { ProgressView("Reading routines…") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("routines.notice") }
                if let book = model.book {
                    if !book.canCreate {
                        Text("Calendar schedules already use this side. Migrate them into complete bedtime routines before editing here; existing schedules are preserved.")
                            .font(.callout).foregroundStyle(Theme.amber)
                    }
                    ForEach(DayOfWeek.weekdays) { day in
                        night(day, book: book)
                    }
                }
                Button("Reload routines") { Task { await model.load() } }.disabled(model.busy).accessibilityIdentifier("routines.reload")
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("routines.scroll").background(Theme.background).navigationTitle("Bedtime routines").navigationBarTitleDisplayMode(.inline)
            .task(id: scope) {
                editor = nil; deleting = nil
                guard phase == .active else { model.invalidate(); return }
                let client: (any BedtimeRoutineClient)? = APIBackend.current.isDemo ? demoClient : (try? CoreRESTClient.configured()).map { CoreBedtimeRoutineClient(transport: $0) }
                model.configure(client: client, side: side); await model.load()
            }
            .onDisappear { model.invalidate() }
            .sheet(item: $editor) { session in NavigationStack { BedtimeRoutineEditor(session: session, model: model) }.tint(Theme.text1) }
            .confirmationDialog("Delete this routine?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let deleting {
                    Button("Delete \(deleting.dayOfWeek.displayName)", role: .destructive) {
                        let input = BedtimeRoutineChanges(side: side, changes: [.init(dayOfWeek: deleting.dayOfWeek, expectedRevision: deleting.revision, replacement: nil)])
                        Task { if await model.save(input) { await schedule.fetchSchedules() } }; self.deleting = nil
                    }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("The selected night's power, temperature phases and alarm will be removed together.") }
    }
    private func night(_ day: DayOfWeek, book: BedtimeRoutineBook) -> some View {
        let snapshot = book.routines.first { $0.dayOfWeek == day }
        return GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(day.displayName).font(.headline)
                if let snapshot { BedtimeRoutineSummary(draft: snapshot.draft, day: day) }
                else { Text("No bedtime routine").font(.footnote).foregroundStyle(Theme.text2) }
                Button(snapshot == nil ? "Create routine" : "Edit routine") { editor = .init(day: day, book: book) }
                    .accessibilityIdentifier("routines.edit.\(day.rawValue)")
                if let snapshot {
                    Button("Delete routine", role: .destructive) { deleting = snapshot }.accessibilityIdentifier("routines.delete.\(day.rawValue)")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(model.busy || !book.canCreate)
    }
}

struct BedtimeRoutineSummary: View {
    let draft: BedtimeRoutineDraft
    let day: DayOfWeek
    var expanded = false
    @Environment(SettingsManager.self) private var settings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.power.enabled ? "Scheduled" : "Paused").font(.caption).foregroundStyle(draft.power.enabled ? Theme.green : Theme.text3)
            Text("\(DisplayTime.clock(draft.power.onTime)) → \(DisplayTime.clock(draft.power.offTime))\(draft.power.offTime < draft.power.onTime ? " next day" : "")").font(.mono(17, relativeTo: .body))
            Text("Start at \(TemperatureDisplay.degrees.text(draft.power.onTemperature, unit: settings.temperatureFormat, includeUnit: true)) · \(draft.temperatures.count) temperature phases").font(.footnote).foregroundStyle(Theme.text2)
            Text(draft.power.endAction.label).font(.footnote).foregroundStyle(Theme.text2)
            if expanded {
                ForEach(Array(draft.normalized.temperatures.enumerated()), id: \.offset) { _, point in
                    Text("\(DisplayTime.clock(point.time)) · \(TemperatureDisplay.degrees.text(point.temperature, unit: settings.temperatureFormat, includeUnit: true))\(point.enabled ? "" : " · Paused")").font(.footnote)
                }
            }
            if let alarm = draft.alarm {
                let alarmDay = BedtimeRoutineTime.eventDay(day, time: alarm.time, start: draft.power.onTime)
                Text("Alarm \(alarmDay.displayName) at \(DisplayTime.clock(alarm.time))\(alarm.enabled ? "" : " · Paused")").font(.footnote)
                if expanded {
                    Text("\(alarm.duration)s vibration · \(alarm.vibrationIntensity)% · \(alarm.vibrationPattern.rawValue.capitalized)").font(.caption)
                    Text("\(alarm.wakeWindow) min wake window · \(alarm.snoozeDuration ?? 300)s snooze · \(alarm.snoozeTaper ?? 0)% duration reduction").font(.caption)
                    Text("Wake at \(TemperatureDisplay.degrees.text(alarm.alarmTemperature, unit: settings.temperatureFormat, includeUnit: true))").font(.caption)
                }
            }
            if !draft.notes.isEmpty { Text(draft.notes).font(.footnote).foregroundStyle(Theme.text2) }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
