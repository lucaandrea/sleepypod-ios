import SwiftUI

struct AutomationActionEditor: View {
    @Binding var action: AutomationAction
    var body: some View {
        Form {
            Picker("Action", selection: Binding(get: { action.kind }, set: { kind in changeKind(kind) })) {
                Text("Set temperature").tag(AutomationAction.Kind.setTemperature)
                Text("Power").tag(AutomationAction.Kind.setPower)
                Text("Notify").tag(AutomationAction.Kind.notify)
            }
            if action.kind == .notify {
                TextField("Message", text: Binding(get: { action.message ?? "" }, set: { action.message = $0 }), axis: .vertical)
            } else {
                Picker("Side", selection: $action.side) {
                    Text("Use rule side").tag(Side?.none)
                    Text("Left").tag(Side?.some(.left)); Text("Right").tag(Side?.some(.right))
                }
                if action.kind == .setPower {
                    Toggle("Power on", isOn: Binding(get: { action.on ?? false }, set: { action.on = $0 }))
                    Toggle("Also set temperature", isOn: Binding(get: { action.temp != nil }, set: { action.temp = $0 ? .literal(72) : nil }))
                }
                if action.temp != nil {
                    NavigationLink { AutomationExpressionEditor(expression: Binding(get: { action.temp ?? .literal(72) }, set: { action.temp = $0 })) } label: {
                        VStack(alignment: .leading, spacing: 4) { Text("Temperature expression"); Text(action.temp?.summary ?? "").font(.footnote).foregroundStyle(Theme.text2) }
                    }
                    Text("Temperature expressions and limits use °F, regardless of your display preference. For a delta, choose Calculation and add to the current or target signal.").font(.footnote).foregroundStyle(Theme.text2)
                }
                if action.kind == .setTemperature {
                    Toggle("Limit temperature", isOn: Binding(get: { action.clamp != nil }, set: { action.clamp = $0 ? .init(min: 65, max: 85) : nil }))
                    if let clamp = action.clamp {
                        TextField("Minimum °F", value: Binding(get: { clamp.min }, set: { action.clamp?.min = $0 }), format: .number).keyboardType(.numbersAndPunctuation)
                        TextField("Maximum °F", value: Binding(get: { clamp.max }, set: { action.clamp?.max = $0 }), format: .number).keyboardType(.numbersAndPunctuation)
                    }
                    Toggle("Revert after a duration", isOn: Binding(get: { action.durationSec != nil }, set: { action.durationSec = $0 ? 1800 : nil }))
                    if let seconds = action.durationSec {
                        TextField("Duration in seconds", value: Binding(get: { seconds }, set: { action.durationSec = $0 }), format: .number).keyboardType(.numberPad)
                    }
                }
                Picker("Control", selection: $action.mode) {
                    Text("Controller default").tag(String?.none)
                    Text("Policy").tag(String?.some("policy")); Text("One-shot").tag(String?.some("one-shot"))
                }
                Toggle("Custom hold", isOn: Binding(get: { action.holdMinutes != nil }, set: { action.holdMinutes = $0 ? 30 : nil }))
                if let minutes = action.holdMinutes {
                    Stepper("Hold \(minutes) minutes", value: Binding(get: { minutes }, set: { action.holdMinutes = $0 }), in: 1...1440)
                }
            }
            Section { Text(action.summary).foregroundStyle(Theme.text2); if !action.valid { Text("Check this action’s values before saving.").foregroundStyle(Theme.amber) } }
        }.navigationTitle("Action").navigationBarTitleDisplayMode(.inline)
    }
    private func changeKind(_ kind: AutomationAction.Kind) {
        guard kind != action.kind else { return }
        switch kind {
        case .notify: action = .init(kind: kind, message: "Automation matched")
        case .setPower: action = .init(kind: kind, on: false)
        case .setTemperature: action = .init(kind: kind, temp: .literal(72), clamp: .init(min: 65, max: 85))
        }
    }
}
