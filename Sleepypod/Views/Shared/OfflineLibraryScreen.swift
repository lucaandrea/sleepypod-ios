import FreeSleepKit
import SwiftUI

struct OfflineLibraryScreen: View {
    enum Page: String { case sleep = "Sleep", schedule = "Schedule" }
    let page: Page
    @Environment(OfflineLibrarySession.self) private var saved
    @Environment(DeviceManager.self) private var device
    @State private var side: Side = .left
    @State private var confirmErase = false
    private var calendar: Calendar { SleepCalendar.calendar(timeZone: saved.library.timeZone) }
    private var reading: OfflineReading<[SleepRecord]>? { saved.library.records(for: side) }
    private var nights: [Date] {
        Array(Set((reading?.value ?? []).map { SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) })).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    Picker("Bed side", selection: $side) {
                        Text("Left").tag(Side.left)
                        Text("Right").tag(Side.right)
                    }.pickerStyle(.segmented)
                    if page == .sleep { sleepContent } else { scheduleContent }
                    if let error = saved.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(Theme.background)
            .environment(\.timeZone, calendar.timeZone)
            .navigationTitle(page.rawValue)
            .settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink("Pod connection") { OwnerConnectionView() }
                        Button("Remove saved Pod data", role: .destructive) { confirmErase = true }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Saved data options")
                }
            }
            .confirmationDialog("Remove saved Pod data from this device?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Remove saved Pod data", role: .destructive) { saved.erase() }
            } message: { Text("Records on your Pod and saved personal reports are unchanged. A new private copy will be saved when connected.") }
            .task { saved.restore() }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Viewing saved data", systemImage: "wifi.slash").font(.headline)
            Text("Your Pod is unavailable. These are the last confirmed records; changes on other devices may not appear yet.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            Text("Controls and editing return after reconnection. Nothing is queued to run later.")
                .font(.caption).foregroundStyle(Theme.text2)
            Button(device.isConnecting ? "Connecting…" : "Retry connection") { device.retryConnection() }
                .buttonStyle(.bordered).disabled(device.isConnecting).accessibilityIdentifier("offline.retry")
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
            .accessibilityIdentifier("offline.banner")
    }

    @ViewBuilder private var sleepContent: some View {
        NavigationLink { SavedPersonalReportsScreen() } label: {
            Label("Read saved personal reports", systemImage: "sparkles").frame(minHeight: 44)
        }.accessibilityIdentifier("offline.reports")
        WatchRecordingAssistantLink()
        if let reading {
            syncLabel(reading.savedAt)
            Text("Recent bed recordings").font(.title3.bold())
            Text("Recorded time describes bed presence, not measured time asleep. Gaps remain unknown.")
                .font(.caption).foregroundStyle(Theme.text2)
            ForEach(nights, id: \.self) { night in
                let records = reading.value.filter { calendar.isDate(SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar), inSameDayAs: night) }
                let summary = NightRecordingSummary(records: records)
                VStack(alignment: .leading, spacing: 8) {
                    Text(night, format: .dateTime.weekday(.wide).month(.abbreviated).day()).font(.headline)
                    Label("\(DisplayTime.duration(summary.recordedSeconds)) recorded", systemImage: "bed.double")
                    if summary.gapSeconds > 0 {
                        Label("\(DisplayTime.duration(summary.gapSeconds)) unknown between records", systemImage: "questionmark.circle")
                            .font(.subheadline).foregroundStyle(Theme.amber)
                    }
                    if summary.ongoing { Text("Still open at last sync; duration is not updated offline.").font(.caption).foregroundStyle(Theme.text2) }
                    DisclosureGroup("Recording windows") {
                        ForEach(records) { record in
                            Text("\(dateText(record.enteredBedDate)) – \(record.completedAt.map(dateText) ?? "Open at last sync")")
                                .font(.caption).padding(.vertical, 4)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
            }
            if nights.isEmpty { empty("No recordings in the saved 30-day window") }
        } else { empty("No saved recordings for this side") }
    }

    @ViewBuilder private var scheduleContent: some View {
        if let snapshot = saved.library.schedules {
            syncLabel(snapshot.savedAt)
            Text("Confirmed weekly plan").font(.title3.bold())
            Text("Times use the Pod’s saved timezone: \(saved.library.timeZone). One-time changes made after this sync are not known.")
                .font(.caption).foregroundStyle(Theme.text2)
            let schedule = snapshot.value.schedule(for: side)
            ForEach(DayOfWeek.weekdays) { day in
                let daily = schedule[day]
                VStack(alignment: .leading, spacing: 10) {
                    Text(day.displayName).font(.headline)
                    if let core = schedule.coreSnapshot {
                        ForEach(core.power.filter { $0.dayOfWeek == day.rawValue }, id: \.id) { power in
                            Text(power.enabled ? "Bedtime \(power.onTime) · ends \(power.offTime)" : "Power routine \(power.onTime) is off")
                            if power.enabled { Text("At end: \((power.endAction ?? .turnOff).label)").font(.caption).foregroundStyle(Theme.text2) }
                        }
                        ForEach(core.temperature.filter { $0.dayOfWeek == day.rawValue }.sorted { $0.time < $1.time }, id: \.id) { point in
                            Text("\(point.time) · \(Int(point.temperature))°F\(point.enabled ? "" : " · off")").font(.subheadline)
                        }
                        let alarms = core.alarm.filter { $0.dayOfWeek == day }
                        ForEach(alarms) { alarm in
                            alarmLabel(time: alarm.time, enabled: alarm.enabled, temperature: Int(alarm.alarmTemperature), duration: alarm.duration)
                        }
                        if alarms.isEmpty { Text("No wake alarm").font(.subheadline).foregroundStyle(Theme.text2) }
                    } else {
                        Text(daily.power.enabled ? "Bedtime \(daily.power.on) · ends \(daily.power.off)" : "Power routine off")
                        ForEach(daily.temperatures.keys.sorted(), id: \.self) { time in
                            if let temperature = daily.temperatures[time] { Text("\(time) · \(temperature)°F").font(.subheadline) }
                        }
                        alarmLabel(time: daily.alarm.time, enabled: daily.alarm.enabled, temperature: daily.alarm.alarmTemperature, duration: daily.alarm.duration)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
            }
        } else { empty("No saved schedule") }
    }

    private func alarmLabel(time: String, enabled: Bool, temperature: Int, duration: Int) -> some View {
        Label(enabled ? "Wake \(time) · \(temperature)°F · vibration \(duration)s" : "Alarm \(time) is off", systemImage: "alarm")
            .font(.subheadline).foregroundStyle(enabled ? Theme.text1 : Theme.text2)
    }
    private func syncLabel(_ date: Date) -> some View {
        Label("Last synced \(dateText(date))", systemImage: "clock")
            .font(.caption).foregroundStyle(Theme.text2).accessibilityIdentifier("offline.lastSynced")
    }
    private func empty(_ title: String) -> some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text("Reconnect once to save a private copy for offline reading."))
    }
    private func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone))
    }
}
