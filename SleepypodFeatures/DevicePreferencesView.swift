import SwiftUI

struct DevicePreferencesView: View {
    @Environment(AppModel.self) private var model
    @State private var workspace = PreferencesWorkspace()
    @State private var client: PodClient?
    @State private var loadedRevision = -1
    var body: some View {
        FeaturePage(title: "Pod preferences") {
            if let failure = workspace.failure { Text(failure).foregroundStyle(Theme.red) }
            if let message = workspace.message { Text(message).foregroundStyle(Theme.green) }
            if let draft = workspace.draft, let snapshot = workspace.snapshot {
                PreferenceFields(draft: Binding(get: { workspace.draft ?? draft }, set: { workspace.draft = $0 }), timeZones: snapshot.timeZones)
                    .disabled(workspace.busy)
                Button(workspace.busy ? "Saving…" : "Save device settings") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(workspace.busy || !workspace.dirty || !workspace.valid)
                Button("Reset draft") { workspace.resetDraft() }.buttonStyle(GlassButtonStyle()).disabled(workspace.busy || !workspace.dirty)
                if !workspace.valid { Text("Use names of 1–20 characters and a valid daily time.").foregroundStyle(Theme.red) }
            }
            Button(workspace.busy && workspace.draft == nil ? "Loading…" : "Reload saved settings") { Task { await load() } }
                .buttonStyle(GlassButtonStyle()).disabled(workspace.busy)
            Text("Additional maintenance controls are available in the local web app.").font(.caption).foregroundStyle(Theme.text2)
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
        FeatureSection(title: "Time & temperature", eyebrow: "YOUR POD") {
            FeatureField(title: "Time zone") {
                Picker("Time zone", selection: $draft.timeZone) { ForEach(timeZones, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).tint(Theme.text1).accessibilityLabel("Time zone")
            }
            Text("Changing the timezone shifts when local routines, alarms and daily tasks run.").font(.caption).foregroundStyle(Theme.text2)
            FeatureField(title: "Temperature format") {
                Picker("Temperature format", selection: $draft.temperatureFormat) {
                    Text("Fahrenheit · °F").tag("fahrenheit"); Text("Celsius · °C").tag("celsius")
                }.labelsHidden().pickerStyle(.menu).tint(Theme.text1).accessibilityLabel("Temperature format")
            }
        }
        FeatureSection(title: "Side settings", eyebrow: "EACH SIDE, YOUR WAY") {
            sideFields("Left", side: $draft.left)
            sideFields("Right", side: $draft.right)
            Text("Away mode pauses this side’s routines and temperature controls. It follows the active side. When both sides are away, routines pause.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
        FeatureSection(title: "Daily care", eyebrow: "READY FOR TONIGHT") {
            Toggle("Prime daily", isOn: $draft.primePodDaily.enabled).tint(Theme.green)
            FeatureField(title: "Daily time") {
                DatePicker("Daily time", selection: Binding(get: { AlarmClock.date(draft.primePodDaily.time) },
                    set: { draft.primePodDaily.time = AlarmClock.time($0) }), displayedComponents: .hourAndMinute)
                    .labelsHidden().environment(\.timeZone, TimeZone.gmt).environment(\.locale, Locale(identifier: "en_GB"))
                    .accessibilityLabel("Daily time")
            }
            Text("Uses the Pod timezone. Choose a time when the bed is empty.").font(.caption).foregroundStyle(Theme.text2)
            Toggle("Reboot once a day", isOn: $draft.rebootDaily).tint(Theme.green)
            Text("Daily reboot runs one hour before priming. Daily priming must also be on.").font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private func sideFields(_ title: String, side: Binding<PodPreferences.Side>) -> some View {
        VStack(spacing: 12) {
            FeatureField(title: "\(title) side name") {
                TextField("\(title) side name", text: side.name).textFieldStyle(.plain).accessibilityLabel("\(title) side name")
                    .onChange(of: side.wrappedValue.name) { side.wrappedValue.name = InputText.limit(side.wrappedValue.name, to: 20) }
            }
            Toggle("\(title) Away mode", isOn: side.awayMode).tint(Theme.green)
        }
    }
}
