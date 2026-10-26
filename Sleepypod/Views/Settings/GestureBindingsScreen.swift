import SwiftUI

struct GestureBindingsScreen: View {
    @Environment(UserProfile.self) private var profile
    @State private var model = GestureBindingsWorkspace(client: APIBackend.current.isDemo ? DemoGestureBindingsClient() : CoreGestureBindingsClient())
    @State private var side: Side = .left
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if APIBackend.current.isDemo { Text("DEMO · simulated tap mappings").font(.footnote).foregroundStyle(Theme.amber) }
                Picker("Sleeper", selection: $side) {
                    ForEach(Side.allCases, id: \.self) { Text("\(model.saved?.sides.name($0) ?? $0.displayName) · \($0.displayName)").tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("gestures.side")
                Text("Tap the Pod cover to change temperature or handle an alarm. Choose a gesture to edit its behavior.").font(.subheadline).foregroundStyle(Theme.text2)
                if let saved = model.saved {
                    ForEach(CoverTap.allCases) { tap in
                        let binding = saved.gestures.binding(side, tap: tap)
                        Button { model.open(side, tap: tap) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    HStack(spacing: 4) { ForEach(0..<tap.count, id: \.self) { _ in Circle().frame(width: 6, height: 6) } }.accessibilityHidden(true)
                                    Text(tap.title).font(.headline)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text3)
                                }
                                behavior("Normally", detail: binding?.idleDescription ?? "Not set")
                                behavior("While ringing", detail: binding?.ringingDescription ?? "Not set")
                            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                        }.buttonStyle(.plain).disabled(model.busy || model.mustReload).accessibilityIdentifier("gestures.\(tap.rawValue)")
                    }
                }
                if model.busy { ProgressView("Reading gestures…") }
                if let receipt = model.receipt { Text(receipt).font(.footnote).accessibilityIdentifier("gestures.receipt") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                Button("Reload") { Task { await model.load() } }.disabled(model.busy).accessibilityIdentifier("gestures.reload")
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Tap gestures").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("gestures.content")
            .task { side = profile.defaultSide; if model.saved == nil { await model.load() } }
            .sheet(isPresented: Binding(get: { model.editing != nil }, set: { if !$0 && !model.busy { model.editing = nil } })) {
                NavigationStack { GestureBindingEditor(model: model) }.presentationDetents([.large]).interactiveDismissDisabled(model.busy)
            }
    }
    private func behavior(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(Theme.text2); Text(detail).font(.subheadline).foregroundStyle(Theme.text1) }
    }
}

private struct GestureBindingEditor: View {
    @Bindable var model: GestureBindingsWorkspace
    @State private var confirmRemove = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let current = model.editing {
                    let draft = Binding(get: { model.editing ?? current }, set: { model.editing = $0 })
                    Text("\(current.side.displayName) · \(current.tap.title)").font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 16) {
                        option("Action", selection: draft.actionType, values: [("temperature", "Temperature"), ("alarm", "Alarm / power")], identifier: "action")
                        if current.actionType == "temperature" {
                            option("Direction", selection: draft.temperatureChange, values: [("increment", "Warmer"), ("decrement", "Cooler")], identifier: "direction")
                            Text("Change by \(current.temperatureAmount)°F").font(.headline).monospacedDigit().accessibilityIdentifier("gestures.amountLabel")
                            Stepper("Temperature change", value: draft.temperatureAmount, in: 0...10).labelsHidden()
                                .accessibilityLabel("Temperature change").accessibilityValue("\(current.temperatureAmount) Fahrenheit degrees").accessibilityIdentifier("gestures.amount")
                            Text("The Pod applies whole Fahrenheit-degree changes, regardless of the app’s temperature display.").font(.footnote).foregroundStyle(Theme.text2)
                        } else if current.actionType == "alarm" {
                            option("While an alarm rings", selection: draft.alarmBehavior, values: [("snooze", "Snooze"), ("dismiss", "Stop alarm")], identifier: "ringing")
                            option("When no alarm rings", selection: draft.alarmInactiveBehavior, values: [("none", "Nothing"), ("power", "Power on / off")], identifier: "idle")
                            if let seconds = current.alarmSnoozeDuration {
                                Text("Saved snooze duration: \(seconds) seconds.").font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                    }.cardStyle().disabled(model.busy || model.mustReload)
                    if let issue = current.issue { Text(issue).font(.footnote).foregroundStyle(Theme.amber) }
                    if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                    if model.mustReload {
                        Button("Reload gesture") { Task { await model.load(discard: true) } }.disabled(model.busy).accessibilityIdentifier("gestures.reconcile")
                    } else {
                        Button("Save gesture") { Task { await model.save() } }
                            .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                            .disabled(model.busy || current.issue != nil).accessibilityIdentifier("gestures.save")
                        if model.original != nil {
                            Button("Remove gesture", role: .destructive) { confirmRemove = true }.disabled(model.busy).accessibilityIdentifier("gestures.remove")
                        }
                    }
                    if model.busy { ProgressView("Saving gesture…") }
                }
            }.frame(maxWidth: 560).padding(20).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Edit gesture").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("gestures.editor")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.editing = nil }.disabled(model.busy) } }
            .confirmationDialog("Remove gesture?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await model.remove() } }
                Button("Cancel", role: .cancel) {}
            }
    }
    private func option(_ title: String, selection: Binding<String>, values: [(String, String)], identifier: String) -> some View {
        SettingsChoiceMenu(title: title, selection: selection, options: values, identifier: "gestures.\(identifier)")
    }
}
