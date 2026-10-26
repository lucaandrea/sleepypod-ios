import SwiftUI

struct PersonalComfortEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: PersonalComfortWorkspace
    let original: PersonalComfortConfig
    let features: PersonalComfortStatus.Features
    @State private var draft: PersonalComfortConfig
    init(model: PersonalComfortWorkspace, original: PersonalComfortConfig, features: PersonalComfortStatus.Features) {
        self.model = model; self.original = original; self.features = features; _draft = State(initialValue: original.editable)
    }
    private var valid: Bool { (try? draft.validate()) != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupedCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Mode", selection: $draft.mode) { Text("Off").tag("off"); Text("Preview").tag("preview") }.pickerStyle(.segmented).accessibilityIdentifier("comfort.config.mode")
                        Text("Preview records proposals while your existing schedules remain in control.").font(.footnote).foregroundStyle(Theme.text2)
                        if original.mode == "active" { Text("Saving these settings stops Active operation and revokes its owner activation. A new activation review is required to resume adjustments.").font(.footnote).foregroundStyle(Theme.amber) }
                        Stepper("Minimum \(draft.minimumF)°F", value: $draft.minimumF, in: 55...110).accessibilityIdentifier("comfort.minimum")
                        Stepper("Maximum \(draft.maximumF)°F", value: $draft.maximumF, in: 55...110).accessibilityIdentifier("comfort.maximum")
                        if !valid { Text("Minimum must not exceed maximum.").font(.footnote).foregroundStyle(Theme.amber) }
                    }.padding(16)
                }
                GroupedCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Use Pod sensor guard", isOn: Binding(get: { draft.sensorAware == true }, set: { draft.sensorAware = $0; if !$0 { draft.followBedtime = false } }))
                            .disabled(!features.sensorAware).accessibilityIdentifier("comfort.sensorGuard")
                        Text("Hold proposals when qualified readings are missing or both recent summaries differ substantially from your personal baseline.").font(.footnote).foregroundStyle(Theme.text2)
                        Divider()
                        Toggle("Follow bed entry", isOn: Binding(get: { draft.followBedtime == true }, set: { draft.followBedtime = $0 }))
                            .disabled(!features.followBedtime || draft.sensorAware != true).accessibilityIdentifier("comfort.followBedtime")
                        Text("Requires the sensor guard and ten minutes of fresh observed presence. Intermediate temperature phases can shift by at most 30 minutes. Power and alarm times remain fixed.").font(.footnote).foregroundStyle(Theme.text2)
                    }.padding(16)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                Text("Active adjustments require a separate owner qualification and activation review.").font(.footnote).foregroundStyle(Theme.text2)
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Preview settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { if await model.save(draft, original: original) { dismiss() } } }.disabled(!valid || model.saving || model.loading || model.status == nil).accessibilityIdentifier("comfort.config.save") }
            }.interactiveDismissDisabled(model.saving)
    }
}

struct PersonalComfortSignalsCard: View {
    let signals: PersonalComfortSignals?
    private var label: String {
        switch signals?.state {
        case "learning": "Building your baseline"
        case "ready": "Comparison ready"
        case "review": "Proposal held"
        default: "Waiting for evidence"
        }
    }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Pod baseline").font(.headline)
                Text(label).font(.subheadline)
                Text(signals?.reason ?? "No current sensor evaluation is available.").font(.footnote).foregroundStyle(Theme.text2)
                ComfortValueRow("Qualified days", value: signals.map { "\($0.baselineDays) / 7 minimum" } ?? "Unavailable")
                ComfortValueRow("Heart-rate baseline", value: signals?.baselineHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "Learning")
                ComfortValueRow("Five-minute summaries", value: signals?.recentHeartRates.count == 2 ? signals!.recentHeartRates.map { "\(Int($0.rounded()))" }.joined(separator: " → ") + " bpm" : "Incomplete")
                Text("Each summary needs five qualified minute estimates. A baseline day needs twelve summaries; days carry equal weight. Apple Health remains a separate comparison source.").font(.footnote).foregroundStyle(Theme.text2)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("comfort.baseline")
    }
}
