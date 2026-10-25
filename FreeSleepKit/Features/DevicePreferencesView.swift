import SwiftUI

struct DevicePreferencesView: View {
    @Environment(AppModel.self) private var model
    @State private var workspace = PreferencesWorkspace()
    @State private var client: PodClient?
    @State private var loadedRevision = -1
    var body: some View {
        SleepPage(title: "Device settings", subtitle: "Changes apply to this Pod in both apps. Review your edits, then save.", narrow: true) {
            if let failure = workspace.failure { Text(failure).foregroundStyle(SleepTheme.error) }
            if let message = workspace.message { Text(message).foregroundStyle(SleepTheme.success) }
            if let draft = workspace.draft, let snapshot = workspace.snapshot {
                PreferenceFields(draft: Binding(get: { workspace.draft ?? draft }, set: { workspace.draft = $0 }), timeZones: snapshot.timeZones)
                    .disabled(workspace.busy)
                Button(workspace.busy ? "Saving…" : "Save device settings") { Task { await save() } }
                    .buttonStyle(SleepButtonStyle(kind: .primary)).disabled(workspace.busy || !workspace.dirty || !workspace.valid)
                Button("Reset draft") { workspace.resetDraft() }.buttonStyle(SleepButtonStyle()).disabled(workspace.busy || !workspace.dirty)
                if !workspace.valid { Text("Use names of 1–20 characters and a valid daily time.").foregroundStyle(SleepTheme.error) }
            }
            Button(workspace.busy && workspace.draft == nil ? "Loading…" : "Reload saved settings") { Task { await load() } }
                .buttonStyle(SleepButtonStyle()).disabled(workspace.busy)
            Text("Additional maintenance controls are available in the local web app.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }.navigationBarTitleDisplayMode(.inline)
            .task(id: model.connectionRevision) { workspace.invalidate(); await load() }
    }
    private func load() async {
        loadedRevision = model.connectionRevision
        await workspace.load {
            if model.demo {
                guard let snapshot = model.demoPreferences else { throw PodError.message("Sample preferences could not be loaded.") }
                return snapshot
            }
            let connection = try PodClient.configured(); client = connection
            return try await connection.get("settings/preferences")
        }
    }
    private func save() async {
        let result = await workspace.save { change in
            guard loadedRevision == model.connectionRevision else { throw PodError.message("Your connection changed. Reload settings before saving.") }
            if model.demo {
                guard var snapshot = model.demoPreferences, snapshot.podID == change.podID, snapshot.preferences == change.expected else {
                    throw PodError.message("An edited setting changed elsewhere. Reload settings and review your changes.")
                }
                snapshot.preferences = change.preferences; return snapshot
            }
            guard let client, (try PodClient.configured()).baseURL == client.baseURL else { throw PodError.message("Your connection changed. Reload settings before saving.") }
            return try await client.postReturning("settings/preferences", body: change)
        }
        if let result, loadedRevision == model.connectionRevision { model.preferencesChanged(result) }
    }
}

private struct PreferenceFields: View {
    @Binding var draft: PodPreferences
    let timeZones: [String]
    var body: some View {
        SleepCard(title: "Time & temperature", eyebrow: "YOUR POD") {
            SleepFormField(title: "Time zone") {
                Picker("Time zone", selection: $draft.timeZone) { ForEach(timeZones, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).tint(SleepTheme.text).accessibilityLabel("Time zone")
            }
            Text("Changing the timezone shifts when local routines, alarms and daily tasks run.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            SleepFormField(title: "Temperature format") {
                Picker("Temperature format", selection: $draft.temperatureFormat) {
                    Text("Fahrenheit · °F").tag("fahrenheit"); Text("Celsius · °C").tag("celsius")
                }.labelsHidden().pickerStyle(.menu).tint(SleepTheme.text).accessibilityLabel("Temperature format")
            }
        }
        SleepCard(title: "Side settings", eyebrow: "EACH SIDE, YOUR WAY") {
            sideFields("Left", side: $draft.left)
            sideFields("Right", side: $draft.right)
            Text("Away mode pauses this side’s routines and temperature controls. It follows the active side. When both sides are away, routines pause.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }
        SleepCard(title: "Daily care", eyebrow: "READY FOR TONIGHT") {
            Toggle("Prime daily", isOn: $draft.primePodDaily.enabled).tint(SleepTheme.accent)
            SleepFormField(title: "Daily time") {
                DatePicker("Daily time", selection: Binding(get: { AlarmClock.date(draft.primePodDaily.time) },
                    set: { draft.primePodDaily.time = AlarmClock.time($0) }), displayedComponents: .hourAndMinute)
                    .labelsHidden().environment(\.timeZone, TimeZone.gmt).environment(\.locale, Locale(identifier: "en_GB"))
                    .accessibilityLabel("Daily time")
            }
            Text("Uses the Pod timezone. Choose a time when the bed is empty.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            Toggle("Reboot once a day", isOn: $draft.rebootDaily).tint(SleepTheme.accent)
            Text("Daily reboot runs one hour before priming. Daily priming must also be on.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }
    }
    private func sideFields(_ title: String, side: Binding<PodPreferences.Side>) -> some View {
        VStack(spacing: 12) {
            SleepFormField(title: "\(title) side name") {
                TextField("\(title) side name", text: side.name).textFieldStyle(.plain).accessibilityLabel("\(title) side name")
                    .onChange(of: side.wrappedValue.name) { side.wrappedValue.name = InputText.limit(side.wrappedValue.name, to: 20) }
            }
            Toggle("\(title) Away mode", isOn: side.awayMode).tint(SleepTheme.accent)
        }
    }
}
