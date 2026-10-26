import SwiftUI

struct PumpProtectionSettingsScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: PumpProtectionWorkspace
    init(client: (any PumpProtectionClient)? = nil) {
        _model = State(initialValue: .init(client: client ?? (APIBackend.current.isDemo ? DemoPumpProtectionClient() : CorePumpProtectionClient())))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated protection settings").font(.footnote).foregroundStyle(Theme.amber) }
                Text("Stops thermal power when reported pump speed stays below the threshold. Automatic recovery can clear the block when speed remains above its recovery threshold.").font(.footnote).foregroundStyle(Theme.text2)
                if let error = model.error { Text(error).foregroundStyle(Theme.amber) }
                if let notice = model.notice { Text(notice).foregroundStyle(Theme.green).accessibilityIdentifier("pump.notice") }
                if let draft = model.draft {
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Pump-stall protection", isOn: Binding(get: { model.draft?.pumpStallProtectionEnabled ?? draft.pumpStallProtectionEnabled }, set: { model.draft?.pumpStallProtectionEnabled = $0 }))
                            valueControl("Stall threshold", unit: "rpm", value: Binding(get: { model.draft?.pumpStallRpmThreshold ?? draft.pumpStallRpmThreshold }, set: { model.draft?.pumpStallRpmThreshold = $0 }), range: 100...1500, step: 50, identifier: "pump.threshold")
                            valueControl("Stall dwell", unit: "samples", value: Binding(get: { model.draft?.pumpStallDwellSamples ?? draft.pumpStallDwellSamples }, set: { model.draft?.pumpStallDwellSamples = $0 }), range: 1...10, identifier: "pump.stallDwell")
                            Toggle("Automatic recovery", isOn: Binding(get: { model.draft?.pumpStallAutoRecoveryEnabled ?? draft.pumpStallAutoRecoveryEnabled }, set: { model.draft?.pumpStallAutoRecoveryEnabled = $0 }))
                            valueControl("Recovery threshold", unit: "rpm", value: Binding(get: { model.draft?.pumpStallRecoveryRpm ?? draft.pumpStallRecoveryRpm }, set: { model.draft?.pumpStallRecoveryRpm = $0 }), range: 500...3000, step: 100, identifier: "pump.recoveryThreshold")
                            valueControl("Recovery dwell", unit: "samples", value: Binding(get: { model.draft?.pumpStallRecoverySamples ?? draft.pumpStallRecoverySamples }, set: { model.draft?.pumpStallRecoverySamples = $0 }), range: 1...10, identifier: "pump.recoveryDwell")
                        }.padding(16)
                    }.disabled(model.busy || model.mustReload)
                    Button("Save protection settings") { Task { await model.save() } }.disabled(!model.changed || model.busy || model.mustReload)
                }
                if model.busy { ProgressView() }
                Button("Reload saved settings") { Task { await model.load() } }.disabled(model.busy)
                if model.changed { Text("Reloading replaces unsaved edits.").font(.caption).foregroundStyle(Theme.text2) }
            }.padding(16)
        }.accessibilityIdentifier("pump.content").background(Theme.background).navigationTitle("Pump protection").navigationBarTitleDisplayMode(.inline).task { await model.load() }
    }
    // Keep the control separate from a wrapping label at accessibility text sizes.
    private func valueControl(_ title: String, unit: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(Theme.text2)
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
            layout {
                Text("\(value.wrappedValue) \(unit)").monospacedDigit()
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Stepper(title, value: value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue("\(value.wrappedValue) \(unit)")
                    .accessibilityIdentifier(identifier)
            }
        }
    }
}
