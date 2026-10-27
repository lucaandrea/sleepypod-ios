import SwiftUI

/// Shared context for Cards, Stage, Slider and the two-side layout.
struct TemperatureContextCards: View {
    let side: Side
    @Environment(HomeRoomSession.self) private var homeRoom
    @Environment(BedroomSession.self) private var bedroom
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspace = TemperatureContextWorkspace()
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 16) {
            if bedroom.workspace?.status?.config.sources.isEmpty == false { BedroomDevicesCard(compact: true) }
            else if homeRoom.workspace?.status?.config.mappings.isEmpty == false { HomeRoomSummaryCard(compact: true) }
            TemperatureHistoryLink()
            if workspace.side != side || (workspace.loading && workspace.result == nil) {
                ProgressView("Loading room and sleep…").frame(maxWidth: .infinity).cardStyle()
            } else if let result = workspace.result {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    RoomContextCard(room: result.room, light: result.light, side: side, unit: settings.temperatureFormat.degreeUnit, now: context.date)
                }
                RecentSleepContextCard(result: result.sleep, sideName: settings.sideName(for: side), timeZone: settings.timeZone)
                if result.room.error != nil || result.light.error != nil || result.sleep.error != nil || result.sleep.value?.vitals.error != nil {
                    Button("Reload room and sleep", systemImage: "arrow.clockwise") { refresh += 1 }
                        .buttonStyle(.bordered).disabled(workspace.loading)
                }
            }
        }.frame(maxWidth: 720).frame(maxWidth: .infinity)
        .task(id: "\(side.rawValue)-\(scenePhase)-\(refresh)") {
            guard scenePhase == .active else { return }
            let client: any TemperatureContextClient = APIBackend.current.isDemo ? DemoTemperatureContextClient(scenario: DebugRoute.temperatureContextScenario) : CoreTemperatureContextClient()
            repeat {
                await workspace.load(side: side, client: client)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

private struct RoomContextCard: View {
    let room: TemperatureContextValue<RoomSnapshot>
    let light: TemperatureContextValue<LightSnapshot>
    let side: Side
    let unit: TemperatureFormat
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let fresh = RoomSnapshot.isFresh(room.value?.date, now: now)
        VStack(alignment: .leading, spacing: 16) {
            HStack { Eyebrow("ROOM").accessibilityIdentifier("temperature.room.title"); Spacer(); lightReading }
            if let error = room.error { feedback("Room unavailable: \(error)") }
            else {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                layout {
                    reading("Inside", value: fresh ? temperature(room.value?.ambientTemp) : "—")
                    reading("Humidity", value: fresh ? humidity(room.value?.humidity) : "—")
                    reading("Bed air", value: fresh ? temperature(room.value?.bedAir(side: side)) : "—")
                }
                if let date = room.value?.date {
                    Text("\(fresh ? "Measured" : "No fresh readings · last measured") \(age(date))")
                        .font(.caption2).foregroundStyle(fresh ? Theme.text3 : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                } else { Text("No room readings yet").font(.footnote).foregroundStyle(Theme.text2) }
            }
            if let error = light.error { feedback("Light unavailable: \(error)") }
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    @ViewBuilder private var lightReading: some View {
        if let value = light.value, RoomSnapshot.isFresh(value.date, now: now), let lux = value.lux, lux.isFinite, lux >= 0 {
            Label("\(lux.formatted(.number.precision(.fractionLength(0)))) lx", systemImage: lux < 10 ? "moon" : "sun.max")
                .font(.caption).foregroundStyle(Theme.text2).accessibilityLabel("Room light, \(lux.formatted(.number.precision(.fractionLength(0)))) lux")
        } else { Text("Light —").font(.caption).foregroundStyle(Theme.text3) }
    }
    private func reading(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.mono(23, weight: .light, relativeTo: .title3))
            Text(title).font(.caption).foregroundStyle(Theme.text2)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(value)
    }
    private func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        let value = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        return value.formatted(.number.precision(.fractionLength(1))) + (unit == .celsius ? "°C" : "°F")
    }
    private func humidity(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0))) + "%"
    }
    private func age(_ date: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 5 { return "just now" }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
    private func feedback(_ message: String) -> some View {
        Text(message).font(.footnote).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecentSleepContextCard: View {
    let result: TemperatureContextValue<RecentSleepContext>
    let sideName: String
    let timeZone: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("LATEST SLEEP · \(sideName.uppercased())")
            if let error = result.error { feedback("Sleep unavailable: \(error)") }
            else if let context = result.value {
                Button {
                    NotificationCenter.default.post(name: .showSleepRecord, object: context.record)
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(context.record.durationFormatted).font(.mono(30, weight: .light, relativeTo: .title))
                            Text(date(context.record.enteredBedDate)).font(.subheadline)
                            Text("\(clock(context.record.enteredBedDate)) → \(context.record.completedAt.map(clock) ?? "Still in bed") · \(context.record.timesExitedBed) \(context.record.timesExitedBed == 1 ? "exit" : "exits")")
                                .font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text3)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("temperature.recentSleep")
                    .accessibilityLabel("View sleep for \(sideName), \(date(context.record.enteredBedDate)), \(context.record.durationFormatted)")
                Divider().overlay(Theme.track)
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                layout {
                    vital("Heart rate", value: context.vitals.value?.avgHeartRate, unit: "bpm")
                    vital("HRV", value: context.vitals.value?.comparableHRV, unit: "ms")
                    vital("Breathing", value: context.vitals.value?.avgBreathingRate, unit: "br/min")
                }
                if let error = context.vitals.error { feedback("Vitals unavailable: \(error)") }
                else { Text(context.vitals.value?.note ?? "No vitals recorded for this session").font(.caption2).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true) }
            } else { Text("No sleep recorded yet").font(.footnote).foregroundStyle(Theme.text2) }
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    private func vital(_ title: String, value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.flatMap { $0.isFinite ? $0.formatted(.number.precision(.fractionLength(0))) : nil } ?? "—")
                .font(.mono(23, weight: .light, relativeTo: .title3))
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(unit).font(.caption2).foregroundStyle(Theme.text3)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func date(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone); formatter.dateStyle = .medium
        return formatter.string(from: value)
    }
    private func clock(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone); formatter.timeStyle = .short
        return formatter.string(from: value)
    }
    private func feedback(_ message: String) -> some View {
        Text(message).font(.footnote).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
    }
}
