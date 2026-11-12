import SwiftUI

struct BedtimeRitualScreen: View {
    let workspace: BedtimeRitualWorkspace
    var isExample = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmPause = false
    var body: some View {
        ScrollViewReader { scroll in
            Form {
                Section {
                    if isExample { Text("Audio example · no speakers connected").font(.caption).foregroundStyle(Theme.text2) }
                    Label("Endel, ready for bed", systemImage: "moon.zzz").font(.headline)
                    Text("Start your saved audio Shortcut, then check the sound at your bedside.")
                }
                if let model = workspace.session, model.available, model.state != nil {
                    contents(model)
                } else {
                    Section {
                        if workspace.busy { ProgressView("Connecting to your account…") }
                        else {
                            Text(workspace.error ?? workspace.session?.error ?? "Connect to your Pod to check shared quiet time before starting audio.")
                                .accessibilityIdentifier("bedtime.connectionError")
                            Text(workspace.connectionInstructions).font(.footnote)
                                .accessibilityIdentifier("bedtime.connectionInstructions")
                            Button("Try connection again") { Task { await workspace.prepare() } }
                                .accessibilityIdentifier("bedtime.retry")
                        }
                    }
                    Section("If audio is still playing") {
                        Text("Open Endel on this device and tap Pause. Check your speakers to confirm it stopped. Losing this account’s connection does not stop external audio.")
                            .accessibilityIdentifier("bedtime.manualStop")
                    }
                }
            }
            .onChange(of: workspace.session?.state?.attempt?.requestId) { _, request in
                if request != nil { scroll.scrollTo("bedtime.latest", anchor: .top) }
            }
            .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Bedtime audio").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    workspace.checkAccount(); workspace.session?.expire()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }
    @ViewBuilder private func contents(_ model: BedtimeRitualSession) -> some View {
        if let attempt = model.state?.attempt { result(attempt, model: model) }
        if let error = model.error {
            Section { Label(error, systemImage: "exclamationmark.circle").accessibilityIdentifier("bedtime.error") }
        }
        if let setup = model.state?.setup {
            Section {
                BedtimeRitualPlanRows(plan: setup.plan)
                Button { Task { await model.launch(.start) } } label: {
                    Label(model.busy ? "Checking and handing off…" : "Start Endel", systemImage: "play.fill")
                        .frame(minHeight: 44)
                }.disabled(model.busy || model.needsReview).accessibilityIdentifier("bedtime.start")
                NavigationLink("Change audio setup") { BedtimeRitualSetupScreen(model: model) }
                    .disabled(model.busy || model.needsReview).accessibilityIdentifier("bedtime.edit")
            } header: { Text("Your reviewed setup") } footer: {
                Text("Start checks shared quiet time, then opens Shortcuts. These are the settings you reviewed—not a live speaker reading.")
            }
        } else {
            Section {
                Text("Connect your saved Start and Pause Shortcuts once. Choose the speakers, volume and timer you want them to use.")
                NavigationLink("Set up bedtime audio") { BedtimeRitualSetupScreen(model: model) }
                    .accessibilityIdentifier("bedtime.setup")
            }
        }
        Section { BedtimeRitualManualHelp(plan: model.state?.setup?.plan) }
    }
    private func result(_ attempt: BedtimeRitualAttempt, model: BedtimeRitualSession) -> some View {
        Section {
            Label(attempt.resultTitle, systemImage: attempt.resultSymbol).font(.headline)
                .accessibilityIdentifier("bedtime.result")
            Text(attempt.resultDetail).accessibilityIdentifier("bedtime.resultDetail")
            Text("\(attempt.action == .start ? "Start" : "Pause") requested \(attempt.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote).foregroundStyle(Theme.text2)
            if let playback = attempt.playback {
                Text("You reported: \(playback.observation.displayName) · \(playback.observedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).accessibilityIdentifier("bedtime.observation")
            } else { Text(attempt.unconfirmedObservation).font(.subheadline).accessibilityIdentifier("bedtime.observation") }
            if attempt.canObserve(at: .now) {
                if attempt.action == .start {
                    Button("I hear it on these speakers") { model.observe(.heardOnSelectedSpeakers) }.accessibilityIdentifier("bedtime.heard")
                    Button("I don’t hear it") { model.observe(.notHeard) }.accessibilityIdentifier("bedtime.notHeard")
                }
                Button("I checked: the audio stopped") { model.observe(.stopped) }.accessibilityIdentifier("bedtime.stopped")
            }
            if model.needsReview {
                Button("I’ve checked Endel—finish this review") { model.acknowledgeResult() }
                    .disabled(model.busy).accessibilityIdentifier("bedtime.reviewed")
            }
            if attempt.canRequestPause(at: .now) {
                Button("Pause this bedtime audio", systemImage: "pause.fill") { confirmPause = true }
                    .disabled(model.busy).accessibilityIdentifier("bedtime.pause")
                    .confirmationDialog("Is this still the bedtime audio you started?", isPresented: $confirmPause, titleVisibility: .visible) {
                        Button("Yes, run my Pause Shortcut") { Task { await model.launch(.pause, confirmsCurrentAudio: true) } }
                        Button("Cancel", role: .cancel) { }
                    } message: { Text("Only continue if no call, other audio or new speaker route has taken over. Otherwise pause directly in Endel.") }
            }
        } header: { Text("Latest handoff") } footer: {
            Text("Shortcut completion and your playback check are separate. Nothing is resent automatically.")
        }.id("bedtime.latest")
    }
}

struct BedtimeRitualPlanRows: View {
    let plan: BedtimeRitualPlan
    var body: some View {
        LabeledContent("Mode", value: plan.mode == .sleep ? "Sleep" : "Relax")
        LabeledContent("Speakers", value: plan.speakerName)
        LabeledContent("Volume", value: "\(plan.volumePercent)%")
        LabeledContent("Timer", value: "\(plan.durationMinutes) minutes")
    }
}
