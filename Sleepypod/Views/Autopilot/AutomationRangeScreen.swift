import SwiftUI

struct AutomationRangeScreen: View {
    let definition: AutomationDefinition
    @State private var model: AutomationRangeWorkspace
    init(definition: AutomationDefinition, client: any AutomationClient) {
        self.definition = definition; _model = State(initialValue: AutomationRangeWorkspace(client: client))
    }
    var body: some View {
        Form {
            Section {
                Text(definition.name).font(.headline)
                Text("Replay this draft over recent recorded nights without saving it or sending bed commands.").foregroundStyle(Theme.text2)
                Text("\(definition.side?.rawValue.capitalized ?? "Both sides") · \(definition.conditions.summary)").font(.footnote)
            }
            Section("Recorded nights") {
                Stepper("Up to \(model.nights) nights", value: $model.nights, in: 1...14)
                Text("For both sides, the night count is the larger side count. Firings are added across both sides.").font(.footnote).foregroundStyle(Theme.text2)
                Button(model.running ? "Replaying…" : "Replay recent nights") { Task { await model.run(definition) } }
                    .disabled(model.running || definition.validation != nil).accessibilityIdentifier("automation.runRange")
                if let error = model.error { Text(error).foregroundStyle(Theme.amber) }
            }
            if let result = model.result {
                Section("Replay summary") {
                    if !model.isCurrent(definition) { Text("The draft or night count changed. Run again to update this summary.").foregroundStyle(Theme.amber) }
                    Text(result.headline).accessibilityIdentifier("automation.rangeSummary")
                    if let low = result.low, let peak = result.peak {
                        Text("Compared value: \(low.formatted(.number.precision(.fractionLength(0...2))))–\(peak.formatted(.number.precision(.fractionLength(0...2))))")
                    } else { Text("No compared signal range returned.").foregroundStyle(Theme.text2) }
                    if let threshold = result.threshold { Text("Threshold: \(threshold.formatted(.number.precision(.fractionLength(0...2))))") }
                    Text("Compared values use the rule’s signal units. These counts describe replayed rule firings, not commands sent to the bed.").font(.footnote).foregroundStyle(Theme.text2)
                    if APIBackend.current.isDemo { Text("Demo has no recorded controller nights.").font(.footnote).foregroundStyle(Theme.amber) }
                }
            }
        }.navigationTitle("Recent nights").navigationBarTitleDisplayMode(.inline)
    }
}
