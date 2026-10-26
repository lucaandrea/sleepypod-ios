import SwiftUI

struct DevicePreferencesScreen: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(SettingsManager.self) private var settings
    @Environment(StatusManager.self) private var status
    @State private var model = DevicePreferencesWorkspace(client: APIBackend.current.isDemo ? DemoDevicePreferencesClient() : CoreDevicePreferencesClient())
    @State private var confirmReload = false
    @State private var choosingTimezone = false
    @State private var confirmRestart = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if APIBackend.current.isDemo { Text("DEMO · simulated device settings").font(.footnote).foregroundStyle(Theme.amber) }
                if let current = model.draft {
                    let draft = Binding(get: { model.draft ?? current }, set: { model.draft = $0 })
                    Group {
                        podCard(draft)
                        powerCard(draft)
                        maintenanceCard(draft)
                        ledCard(draft)
                        if let issue = current.issue { Text(issue).font(.footnote).foregroundStyle(Theme.amber) }
                        Button(typeSize.isAccessibilitySize ? "Save" : "Save device settings") { Task { await save() } }
                            .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                            .disabled(!model.dirty || model.mustReload || current.issue != nil).accessibilityLabel("Save device settings").accessibilityIdentifier("devicePreferences.save")
                    }.disabled(model.busy)
                }
                if model.busy { ProgressView(model.restarting ? "Requesting restart…" : "Reading device settings…") }
                if let receipt = model.receipt { Text(receipt).font(.footnote).accessibilityIdentifier("devicePreferences.receipt") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                NavigationLink { PumpProtectionSettingsScreen() } label: { Label("Pump protection", systemImage: "shield") }
                sensorSourceCard
                Button("Reconnect & reload") {
                    if model.dirty { confirmReload = true } else { Task { await reconnect() } }
                }.disabled(model.busy).accessibilityIdentifier("devicePreferences.reload")
                Button("Restart controller service", role: .destructive) { confirmRestart = true }
                    .disabled(model.saved == nil || model.busy || model.dirty || model.mustReload || model.restartNeedsReconnect)
                    .accessibilityIdentifier("devicePreferences.restart")
                if model.dirty { Text("Save or discard edits before restarting.").font(.footnote).foregroundStyle(Theme.text2) }
                if let receipt = model.restartReceipt { Text(receipt).font(.footnote).accessibilityIdentifier("devicePreferences.restartReceipt") }
                NavigationLink { SystemHealthScreen() } label: { Label("Service health & recovery", systemImage: "waveform.path.ecg") }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Device").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("devicePreferences.content")
            .task {
                if model.saved == nil { await model.load() }
                while !Task.isCancelled {
                    await model.refreshSource()
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
            .sheet(isPresented: $choosingTimezone) {
                NavigationStack { DeviceTimezonePicker(current: model.draft?.timezone ?? "", choose: { model.draft?.timezone = $0; choosingTimezone = false }) }
            }
            .confirmationDialog("Discard unsaved device changes?", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("Reload settings", role: .destructive) { Task { await reconnect() } }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $confirmRestart) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Restart controller service").font(.title2.weight(.semibold))
                            Text("The Pod will be briefly unavailable. Reconnect afterwards to read its current status.")
                            Button("Restart service", role: .destructive) {
                                confirmRestart = false
                                Task { await model.restart() }
                            }.buttonStyle(.borderedProminent).tint(Theme.red)
                        }.frame(maxWidth: 560, alignment: .leading).padding(20).frame(maxWidth: .infinity)
                    }.background(Theme.background).navigationTitle("Restart").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmRestart = false } } }
                }.presentationDetents([.large])
            }
    }
    private func podCard(_ draft: Binding<DevicePreferences>) -> some View {
        card("POD") {
            Button { choosingTimezone = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Timezone").font(.subheadline.weight(.semibold))
                    Label(draft.wrappedValue.timezone.replacingOccurrences(of: "_", with: " "), systemImage: "globe")
                        .font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.accessibilityIdentifier("devicePreferences.timezone")
            preferenceMenu("Temperature unit", selection: draft.temperatureUnit, options: [("F", "Fahrenheit (°F)"), ("C", "Celsius (°C)")], identifier: "unit")
            preferenceMenu("Time format", selection: draft.timeFormat, options: [("12h", "12-hour"), ("24h", "24-hour")], identifier: "timeFormat")
            Text("Timezone applies to the Pod’s schedules. Changing the clock display preserves scheduled times.").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func powerCard(_ draft: Binding<DevicePreferences>) -> some View {
        card("POWER") {
            preferenceMenu("After schedule ends", selection: draft.defaultScheduleEndAction, options: [("turn_off", "Turn off"), ("maintain", "Maintain final temperature")], identifier: "endAction")
            Text("Default for new curves. Existing schedules keep their own setting.").font(.footnote).foregroundStyle(Theme.text2)
            BridgeToggleRow(title: "Auto power-off cap", value: Binding(get: { draft.wrappedValue.globalMaxOnHours != nil }, set: { draft.wrappedValue.globalMaxOnHours = $0 ? 12 : nil }), identifier: "devicePreferences.powerCap")
            if let hours = draft.wrappedValue.globalMaxOnHours {
                VStack(alignment: .leading, spacing: 8) {
                    Text("After \(hours) hours").monospacedDigit()
                    Stepper("Power-off hours", value: Binding(get: { draft.wrappedValue.globalMaxOnHours ?? hours }, set: { draft.wrappedValue.globalMaxOnHours = $0 }), in: 1...48)
                        .labelsHidden().accessibilityLabel("Power-off hours").accessibilityIdentifier("devicePreferences.capHours")
                }
            }
            Text("Limits how long either side stays on. Always-on sides and run-once sessions are exempt.").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func maintenanceCard(_ draft: Binding<DevicePreferences>) -> some View {
        card("DAILY MAINTENANCE") {
            BridgeToggleRow(title: "Daily reboot", value: Binding(get: { draft.wrappedValue.rebootDaily }, set: {
                draft.wrappedValue.rebootDaily = $0
                if $0 && draft.wrappedValue.rebootTime == nil { draft.wrappedValue.rebootTime = "03:00" }
            }), identifier: "devicePreferences.reboot")
            if draft.wrappedValue.rebootDaily { DeviceClockField(title: "Reboot time", value: draft.rebootTime, fallback: "03:00", identifier: "rebootTime", timeFormat: draft.wrappedValue.timeFormat) }
            BridgeToggleRow(title: "Daily prime", value: Binding(get: { draft.wrappedValue.primePodDaily }, set: {
                draft.wrappedValue.primePodDaily = $0
                if $0 && draft.wrappedValue.primePodTime == nil { draft.wrappedValue.primePodTime = "14:00" }
            }), identifier: "devicePreferences.prime")
            if draft.wrappedValue.primePodDaily { DeviceClockField(title: "Prime time", value: draft.primePodTime, fallback: "14:00", identifier: "primeTime", timeFormat: draft.wrappedValue.timeFormat) }
            Text("Priming circulates water to clear air. These independent daily times use \(draft.wrappedValue.timezone.replacingOccurrences(of: "_", with: " ")).").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func ledCard(_ draft: Binding<DevicePreferences>) -> some View {
        card("LED") {
            brightness("Day brightness", value: draft.ledDayBrightness, identifier: "dayBrightness")
            BridgeToggleRow(title: "Night mode", value: Binding(get: { draft.wrappedValue.ledNightModeEnabled }, set: {
                draft.wrappedValue.ledNightModeEnabled = $0
                if $0 {
                    if draft.wrappedValue.ledNightStartTime == nil { draft.wrappedValue.ledNightStartTime = "22:00" }
                    if draft.wrappedValue.ledNightEndTime == nil { draft.wrappedValue.ledNightEndTime = "07:00" }
                }
            }), identifier: "devicePreferences.ledNight")
            if draft.wrappedValue.ledNightModeEnabled {
                DeviceClockField(title: "Dim from", value: draft.ledNightStartTime, fallback: "22:00", identifier: "nightStart", timeFormat: draft.wrappedValue.timeFormat)
                DeviceClockField(title: "Restore at", value: draft.ledNightEndTime, fallback: "07:00", identifier: "nightEnd", timeFormat: draft.wrappedValue.timeFormat)
                brightness("Night brightness", value: draft.ledNightBrightness, identifier: "nightBrightness")
            }
            Text("Brightness and schedules apply when you save.").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private var sensorSourceCard: some View {
        card("SENSOR DATA SOURCE") {
            if let source = model.source, let received = model.sourceReceivedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(received))
                    let verdict = model.sourceError == nil ? source.status(elapsed: elapsed) : "Unavailable"
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verdict).font(.headline).foregroundStyle(verdict == "Live" ? Theme.green : Theme.amber)
                            .accessibilityIdentifier("devicePreferences.sourceStatus")
                        Text(source.firmware.probed ? source.firmware.label : "No firmware detected").font(.subheadline)
                        Text(source.firmware.probed ? source.firmware.detail : "The controller has not detected Pod firmware.").font(.footnote).foregroundStyle(Theme.text2)
                        Text("Reading from: \(source.sourceLabel)").font(.subheadline)
                        if let age = source.stream.lastFrameAgeMs {
                            Text("Last frame: \(Int((age / 1000 + elapsed).rounded(.down))) s ago\(source.stream.lastFrameType.map { " · \($0)" } ?? "")").font(.footnote).monospacedDigit()
                        } else { Text("No frames received yet.").font(.footnote) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let note = source.note { Text(note).font(.footnote).foregroundStyle(Theme.amber) }
            } else { Text("Sensor source has not been read.").font(.footnote).foregroundStyle(Theme.text2) }
            if let error = model.sourceError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            Text("Selected automatically at startup. Firmware changes require the controller service to re-detect its source.").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func preferenceMenu(_ title: String, selection: Binding<String>, options: [(String, String)], identifier: String) -> some View {
        SettingsChoiceMenu(title: title, selection: selection, options: options, identifier: "devicePreferences.\(identifier)")
    }
    private func brightness(_ title: String, value: Binding<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(value.wrappedValue)%").font(.subheadline.weight(.semibold)).monospacedDigit()
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }), in: 0...100, step: 1)
                .tint(Theme.cool).accessibilityLabel(title).accessibilityValue("\(value.wrappedValue) percent").accessibilityIdentifier("devicePreferences.\(identifier)")
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.text2); content() }.cardStyle()
    }
    private func reconnect() async {
        await model.load(discardDraft: true)
        await model.refreshSource()
        await settings.fetchSettings()
        await status.fetchAll()
    }
    private func save() async {
        let changedUnit = model.draft?.temperatureUnit != model.saved?.temperatureUnit
        await model.save()
        guard model.receipt != nil, !model.mustReload else { return }
        if changedUnit, let unit = model.saved?.temperatureUnit {
            UserDefaults.standard.set(unit == "C" ? "celsius" : "fahrenheit", forKey: "temperatureFormat")
        }
        await settings.fetchSettings()
        if let format = model.saved?.timeFormat { UserDefaults.standard.set(format, forKey: "podTimeFormat") }
    }
}

// Clock-only dates use UTC to avoid the phone's DST rules altering a Pod wall-clock time.
private struct DeviceClockField: View {
    let title: String
    @Binding var value: String?
    let fallback: String
    let identifier: String
    let timeFormat: String
    private var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt; return calendar }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            DatePicker(title, selection: Binding(get: {
                let minutes = DisplayTime.minutes(value ?? fallback)
                return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60)) ?? .distantPast
            }, set: { date in
                let components = calendar.dateComponents([.hour, .minute], from: date)
                value = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.compact).environment(\.timeZone, .gmt)
                .environment(\.locale, DevicePreferences.clockLocale(format: timeFormat))
                .accessibilityLabel(title).accessibilityIdentifier("devicePreferences.\(identifier)")
        }
    }
}

private struct DeviceTimezonePicker: View {
    let current: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var zones: [String] {
        TimeZone.knownTimeZoneIdentifiers.filter { search.isEmpty || $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List(zones, id: \.self) { zone in
            Button { choose(zone) } label: {
                HStack { Text(zone.replacingOccurrences(of: "_", with: " ")); Spacer(); if zone == current { Image(systemName: "checkmark") } }
            }
        }.searchable(text: $search).navigationTitle("Timezone").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
