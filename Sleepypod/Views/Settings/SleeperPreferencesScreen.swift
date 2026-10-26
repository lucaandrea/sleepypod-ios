import SwiftUI

struct SleeperPreferencesScreen: View {
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings
    @State private var model = SleeperPreferencesWorkspace(client: APIBackend.current.isDemo ? DemoSleeperPreferencesClient() : CoreSleeperPreferencesClient())
    var body: some View {
        @Bindable var profile = profile
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if APIBackend.current.isDemo { Text("DEMO · simulated sleeper settings").font(.footnote).foregroundStyle(Theme.amber) }
                Text("Sides as seen lying in bed. Tap a side to make it this iPhone’s default.").font(.subheadline).foregroundStyle(Theme.text2)
                if let current = model.draft {
                    let draft = Binding(get: { model.draft ?? current }, set: { model.draft = $0 })
                    BedSidesEditor(defaultSide: $profile.defaultSide, leftName: draft.sides.left.name, rightName: draft.sides.right.name) { side, name in
                        Task { await model.saveName(side, name: name); await refreshNames() }
                    }.disabled(model.busy || model.mustReload)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("BED SETUP").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                        SettingsChoiceMenu(title: "Sleepers", selection: draft.device.bedMode, options: [("two", "Two sleepers"), ("solo-left", "Solo · left"), ("solo-right", "Solo · right")], identifier: "sleepers.bedMode")
                        Text("Who normally sleeps here. Away mode temporarily pauses a sleeper while preserving this setup.").font(.footnote).foregroundStyle(Theme.text2)
                        SettingsChoiceMenu(title: "Other temperature zone", selection: draft.device.unusedZoneMode, options: [("off", "Stay off"), ("follow", "Follow my schedule"), ("independent", "Use its own schedule")], identifier: "sleepers.otherZone")
                        Text("When one sleeper is home, both zones keep their saved schedules and absent sleepers’ alarms pause. One active sleeper gets one sleep record from sensors across the bed. Manual temperature and power controls remain available for both zones.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                        Button("Save setup") { Task { await model.saveBed(); await refreshNames() } }
                            .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                            .disabled(current.device == model.saved?.device || model.mustReload || current.device.issue != nil)
                            .accessibilityIdentifier("sleepers.saveBed")
                    }.cardStyle().disabled(model.busy)
                    GroupedSection("SLEEPERS") {
                        GroupedCard {
                            ForEach(Side.allCases, id: \.self) { side in
                                NavigationLink { SleeperControlsScreen(model: model, side: side) } label: {
                                    SettingsRow(current.sides[side].name, subtitle: side.displayName, icon: "person", tile: true, chevron: true)
                                }.accessibilityIdentifier("sleepers.\(side.rawValue)")
                            }
                        }
                    }
                }
                SleeperSaveFeedback(model: model)
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively).background(Theme.background).navigationTitle("Sides").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("sleepers.content")
            .task {
                if model.saved == nil { await model.load() }
                await model.observePresence()
            }
    }
    private func refreshNames() async { if model.receipt != nil && !model.mustReload { await settings.fetchSettings() } }
}

private struct SleeperControlsScreen: View {
    @Bindable var model: SleeperPreferencesWorkspace
    let side: Side
    @Environment(SettingsManager.self) private var settings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let current = model.draft?.sides[side], let device = model.draft?.device {
                    let draft = Binding(get: { model.draft?.sides[side] ?? current }, set: { model.draft?.sides[side] = $0 })
                    awayCard(draft)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        // A response can arrive after the timeline's last tick; age it at render time.
                        let available = model.presenceAvailable(side)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("PRESENCE & POWER").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                            Text(available ? "Presence available" : "Presence unavailable").font(.subheadline).foregroundStyle(available ? Theme.green : Theme.amber)
                                .accessibilityIdentifier("sleepers.presence")
                            Text("Presence actions require a fresh, calibrated sensor signal. You can always turn them off.").font(.footnote).foregroundStyle(Theme.text2)
                            BridgeToggleRow(title: "Always on", value: Binding(get: { current.alwaysOn }, set: { draft.wrappedValue.alwaysOn = $0; if $0 { draft.wrappedValue.autoOffEnabled = false } }), identifier: "sleepers.alwaysOn")
                            Text("Keeps this side powered and exempts it from the automatic power-off cap.").font(.footnote).foregroundStyle(Theme.text2)
                            BridgeToggleRow(title: "Auto-off when empty", value: Binding(get: { current.autoOffEnabled }, set: { draft.wrappedValue.autoOffEnabled = $0; if $0 { draft.wrappedValue.alwaysOn = false } }), identifier: "sleepers.autoOff")
                                .disabled(!available && !current.autoOffEnabled)
                            if current.autoOffEnabled { duration("Empty for", value: draft.autoOffMinutes, range: 5...120, identifier: "offMinutes") }
                        }.cardStyle()
                        VStack(alignment: .leading, spacing: 16) {
                            Text("AUTO-ON · EXPERIMENTAL").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                            BridgeToggleRow(title: "Auto-on when in bed", value: draft.autoOnEnabled, identifier: "sleepers.autoOn")
                                .disabled(!available && !current.autoOnEnabled)
                            Text("Ignores light loads and uses your scheduled or last temperature. The window uses the Pod’s timezone: \(device.timezone). Equal start and end times allow any time.")
                                .font(.footnote).foregroundStyle(Theme.text2)
                            if current.autoOnEnabled {
                                duration("In bed for", value: draft.autoOnMinutes, range: 1...60, identifier: "onMinutes")
                                SleeperClockField(title: "Window starts", value: draft.autoOnStart, format: device.timeFormat, identifier: "sleepers.windowStart")
                                SleeperClockField(title: "Window ends", value: draft.autoOnEnd, format: device.timeFormat, identifier: "sleepers.windowEnd")
                            }
                        }.cardStyle()
                    }
                    if let issue = current.issue { Text(issue).font(.footnote).foregroundStyle(Theme.amber) }
                    Button("Save changes") { Task { await model.saveSide(side); if model.receipt != nil && !model.mustReload { await settings.fetchSettings() } } }
                        .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                        .disabled(current == model.saved?.sides[side] || model.mustReload || current.issue != nil)
                        .accessibilityIdentifier("sleepers.saveSide")
                }
                SleeperSaveFeedback(model: model)
            }.disabled(model.busy).frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle(model.draft?.sides[side].name ?? side.displayName).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("sleepers.content")
            .task { await model.observePresence() }
    }
    private func awayCard(_ draft: Binding<SleeperPreferences>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AWAY MODE").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            BridgeToggleRow(title: "Away", value: draft.awayMode, identifier: "sleepers.away")
            Text("Temporarily pauses this sleeper’s tracking and alarms. Their profile and schedules remain saved.").font(.footnote).foregroundStyle(Theme.text2)
            BridgeToggleRow(title: "Return date", value: Binding(get: { draft.wrappedValue.awayReturn != nil }, set: {
                draft.wrappedValue.awayReturn = $0 ? max(Date.now.addingTimeInterval(86400), draft.wrappedValue.awayStart.flatMap(SensorObservation.date) ?? .distantPast).ISO8601Format() : nil
            }), identifier: "sleepers.hasReturn")
            if draft.wrappedValue.awayReturn != nil {
                DatePicker("Return", selection: Binding(get: { draft.wrappedValue.awayReturn.flatMap(SensorObservation.date) ?? .now }, set: { draft.wrappedValue.awayReturn = $0.ISO8601Format() }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().accessibilityLabel("Return date").accessibilityIdentifier("sleepers.returnDate")
                Text("Shown in this iPhone’s local time.").font(.footnote).foregroundStyle(Theme.text2)
            }
            if let start = draft.wrappedValue.awayStart.flatMap(SensorObservation.date) {
                Text("Saved away start: \(start.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(Theme.text2)
            }
        }.cardStyle()
    }
    private func duration(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) \(value.wrappedValue) min").font(.subheadline).monospacedDigit()
            Stepper(title, value: value, in: range).labelsHidden().accessibilityLabel(title).accessibilityValue("\(value.wrappedValue) minutes").accessibilityIdentifier("sleepers.\(identifier)")
        }
    }
}

private struct SleeperSaveFeedback: View {
    let model: SleeperPreferencesWorkspace
    @State private var discard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy { ProgressView("Reading settings…") }
            if !model.dirty, let receipt = model.receipt { Text(receipt).font(.footnote).accessibilityIdentifier("sleepers.receipt") }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            if let error = model.occupancyError { Text("Presence: \(error)").font(.footnote).foregroundStyle(Theme.text2) }
            Button("Reload") {
                if model.dirty { discard = true } else { Task { await model.load(); await model.refreshOccupancy() } }
            }.disabled(model.busy).accessibilityIdentifier("sleepers.reload")
        }.confirmationDialog("Discard edits?", isPresented: $discard, titleVisibility: .visible) {
            Button("Discard & reload", role: .destructive) { Task { await model.load(discard: true); await model.refreshOccupancy() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// Treat HH:mm as a Pod wall clock; the phone's DST must not shift the saved window.
private struct SleeperClockField: View {
    let title: String
    @Binding var value: String
    let format: String
    let identifier: String
    private var calendar: Calendar { var result = Calendar(identifier: .gregorian); result.timeZone = .gmt; return result }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            DatePicker(title, selection: Binding(get: {
                let minutes = DisplayTime.minutes(value)
                return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60)) ?? .distantPast
            }, set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                value = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute).labelsHidden().environment(\.timeZone, .gmt)
                .environment(\.locale, DevicePreferences.clockLocale(format: format))
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}
