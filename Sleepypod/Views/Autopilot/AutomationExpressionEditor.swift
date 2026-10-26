import SwiftUI

/// Each nested editor changes only its bound subtree; opening an existing rule never simplifies its AST.
struct AutomationExpressionEditor: View {
    @Binding var expression: AutomationExpression
    var depth = 1
    private var kind: String {
        switch expression {
        case .literal: "Number"
        case .signal: "Signal"
        case .window: "Aggregate"
        case .binary: "Calculation"
        case .clamp: "Limit"
        }
    }
    var body: some View {
        Form {
            Picker("Value", selection: Binding(get: { kind }, set: { kind in changeKind(kind) })) {
                ForEach(["Number", "Signal", "Aggregate", "Calculation", "Limit"], id: \.self) { Text($0) }
            }
            switch expression {
            case .literal(let number):
                TextField("Number", value: Binding(get: { number }, set: { expression = .literal($0) }), format: .number).keyboardType(.numbersAndPunctuation)
            case .signal(let signal):
                AutomationSignalPicker(signal: Binding(get: { signal }, set: { expression = .signal($0) }))
            case .window(let function, let signal, let minutes):
                Picker("Function", selection: Binding(get: { function }, set: { expression = .window(function: $0, signal: signal, minutes: minutes) })) {
                    ForEach(["avg", "min", "max", "sum", "count"], id: \.self) { Text($0) }
                }
                AutomationSignalPicker(signal: Binding(get: { signal }, set: { expression = .window(function: function, signal: $0, minutes: minutes) }))
                Stepper("Last \(minutes) minutes", value: Binding(get: { minutes }, set: { expression = .window(function: function, signal: signal, minutes: $0) }), in: 1...1440)
            case .binary(let operation, let left, let right):
                Picker("Operation", selection: Binding(get: { operation }, set: { expression = .binary(operation: $0, left: left, right: right) })) {
                    ForEach(["+", "-", "*", "/"], id: \.self) { Text($0) }
                }
                child("First value", binding: Binding(get: { left }, set: { expression = .binary(operation: operation, left: $0, right: right) }))
                child("Second value", binding: Binding(get: { right }, set: { expression = .binary(operation: operation, left: left, right: $0) }))
            case .clamp(let value, let minimum, let maximum):
                child("Value", binding: Binding(get: { value }, set: { expression = .clamp(value: $0, minimum: minimum, maximum: maximum) }))
                child("Minimum", binding: Binding(get: { minimum }, set: { expression = .clamp(value: value, minimum: $0, maximum: maximum) }))
                child("Maximum", binding: Binding(get: { maximum }, set: { expression = .clamp(value: value, minimum: minimum, maximum: $0) }))
            }
            Section { Text(expression.summary).foregroundStyle(Theme.text2) }
        }.navigationTitle("Expression").navigationBarTitleDisplayMode(.inline)
    }
    private func child(_ title: String, binding: Binding<AutomationExpression>) -> some View {
        NavigationLink { AnyView(AutomationExpressionEditor(expression: binding, depth: depth + 1)) } label: {
            VStack(alignment: .leading, spacing: 4) { Text(title); Text(binding.wrappedValue.summary).font(.footnote).foregroundStyle(Theme.text2) }
        }.disabled(depth >= 16)
    }
    private func changeKind(_ kind: String) {
        guard kind != self.kind else { return }
        switch kind {
        case "Signal": expression = .signal("ambient.temperature")
        case "Aggregate": expression = .window(function: "avg", signal: "ambient.temperature", minutes: 10)
        case "Calculation": expression = .binary(operation: "+", left: .signal("left.currentTemperature"), right: .literal(0))
        case "Limit": expression = .clamp(value: .signal("left.currentTemperature"), minimum: .literal(65), maximum: .literal(85))
        default: expression = .literal(0)
        }
    }
}

struct AutomationSignalPicker: View {
    @Binding var signal: String
    private var keys: [String] {
        AutomationSignal.catalog.flatMap { item in item.id.contains("{side}") ? Side.allCases.map { AutomationSignal.concrete(item.id, side: $0) } : [item.id] }
    }
    var body: some View {
        Picker("Signal", selection: $signal) {
            if !keys.contains(signal) { Text(signal).tag(signal) }
            ForEach(keys, id: \.self) { key in Text(AutomationSignal.label(key)).tag(key) }
        }
        TextField("Signal key", text: $signal).textInputAutocapitalization(.never).autocorrectionDisabled()
        if signal.contains("presence") { Text("Presence signals are live only. Recorded-night backtests may not have this signal.").font(.footnote).foregroundStyle(Theme.text2) }
    }
}
