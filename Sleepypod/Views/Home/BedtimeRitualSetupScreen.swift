import SwiftUI

struct BedtimeRitualSetupScreen: View {
    let model: BedtimeRitualSession
    @Environment(\.dismiss) private var dismiss
    @State private var mode: BedtimeRitualPlan.Mode = .sleep
    @State private var startShortcut = "Sleepypod Sleep"
    @State private var pauseShortcut = "Sleepypod Pause"
    @State private var speakers = "Bedside HomePods"
    @State private var volume = 35
    @State private var duration = 60
    @State private var reviewed = false
    @State private var loaded = false
    private var plan: BedtimeRitualPlan {
        .init(revision: UUID(), mode: mode, startShortcut: startShortcut.trimmingCharacters(in: .whitespacesAndNewlines),
              pauseShortcut: pauseShortcut.trimmingCharacters(in: .whitespacesAndNewlines),
              speakerName: speakers.trimmingCharacters(in: .whitespacesAndNewlines), volumePercent: volume, durationMinutes: duration)
    }
    var body: some View {
        Form {
            Section {
                Text("Prepare your two Shortcuts first. This screen remembers what they do; saving here does not create or edit them.")
                NavigationLink("How to prepare the Shortcuts") { BedtimeRitualSetupGuide() }.accessibilityIdentifier("bedtime.guide")
            }
            Section("Exact saved Shortcut names") {
                namedField("Start Shortcut", text: $startShortcut, identifier: "bedtime.startName")
                namedField("Pause Shortcut", text: $pauseShortcut, identifier: "bedtime.pauseName")
            }
            Section("Settings to check in your Shortcut") {
                Picker("Endel mode", selection: $mode) { Text("Sleep").tag(BedtimeRitualPlan.Mode.sleep); Text("Relax").tag(BedtimeRitualPlan.Mode.relax) }
                namedField("Speaker destination", text: $speakers, identifier: "bedtime.speakers")
                Stepper("Volume: \(volume)%", value: $volume, in: 0...100, step: 5).accessibilityIdentifier("bedtime.volume")
                Stepper("Timer: \(duration) minutes", value: $duration, in: 5...720, step: 5).accessibilityIdentifier("bedtime.duration")
                Text("If Endel’s installed action has no timer option, set this timer in Endel before each start.").font(.footnote)
            }
            Section {
                Toggle("I checked both Shortcuts and these settings", isOn: $reviewed).accessibilityIdentifier("bedtime.setupReviewed")
                if let error = model.error { Text(error).accessibilityIdentifier("bedtime.setupError") }
                Button("Save reviewed setup") {
                    let value = plan
                    model.confirmSetup(value)
                    if model.state?.setup?.plan == value { dismiss() }
                }.disabled(!reviewed || (try? plan.validate()) == nil || model.busy || model.needsReview || !model.available)
                    .accessibilityIdentifier("bedtime.saveSetup")
            } footer: { Text("This setup stays on this device, private to your current account. No audio starts when you save.") }
        }
        .navigationTitle("Audio setup").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(Theme.background)
        .task {
            guard !loaded else { return }; loaded = true
            if let saved = model.state?.setup?.plan {
                mode = saved.mode; startShortcut = saved.startShortcut; pauseShortcut = saved.pauseShortcut
                speakers = saved.speakerName; volume = saved.volumePercent; duration = saved.durationMinutes
            }
        }
        .onChange(of: [mode.rawValue, startShortcut, pauseShortcut, speakers, String(volume), String(duration)]) { reviewed = false }
    }
    private func namedField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).accessibilityIdentifier(identifier + ".label")
            TextField(title, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .frame(minHeight: 44).accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}

struct BedtimeRitualManualHelp: View {
    let plan: BedtimeRitualPlan?
    var body: some View {
        DisclosureGroup("Finish in Endel if needed") {
            Text("Open Endel on this device and choose \(plan?.mode == .relax ? "Relax" : "Sleep").")
            Text("Use AirPlay to select \(plan?.speakerName ?? "your bedside speakers"), then check the volume\(plan.map { " is \($0.volumePercent)%" } ?? "").")
            Text("Set Endel’s timer\(plan.map { " to \($0.durationMinutes) minutes" } ?? "") and listen for the audio before marking it confirmed.")
            Text("To stop, pause in Endel. A phone call or another app can change what is playing.")
        }.accessibilityIdentifier("bedtime.manualHelp")
    }
}

struct BedtimeRitualSetupGuide: View {
    var body: some View {
        List {
            Section("Start Shortcut") {
                Text("In Endel, add the Sleep or Relax action to Siri Shortcuts. In Shortcuts, create a named routine using that action.")
                Text("Add the available playback-destination and volume actions for your bedside HomePods. Check their order by running the Shortcut while you are nearby.")
                Text("If the installed Endel action supports a timer, set it there. Otherwise set the timer in Endel each time; a long Wait action is not a reliable overnight timer.")
            }
            Section("Pause Shortcut") {
                Text("Create a separately named Shortcut that pauses this Endel session. Test it on the same speakers. Avoid Play/Pause toggles, which can start stopped audio.")
                Text("If your installed actions cannot pause the intended session reliably, use Endel directly and leave this setup unfinished.")
            }
            Section("Check before saving") {
                Text("Confirm the mode, destination, volume and timer, and test cancellation. Enter the exact two Shortcut names in Audio setup.")
                Text("Sleepypod passes these requested settings as text. A Shortcut only uses that input if you configure it to read the fields; otherwise its own saved settings apply.")
                Text("Quiet time is checked before each Start. This does not automatically stop audio already playing when someone later requests quiet.")
            }
        }.navigationTitle("Prepare your Shortcuts").navigationBarTitleDisplayMode(.inline)
    }
}
