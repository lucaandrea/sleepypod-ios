import SwiftUI

struct AutomationConditionEditor: View {
    @Binding var condition: AutomationCondition
    var depth = 1
    private var kind: String {
        switch condition {
        case .all: "All"
        case .any: "Any"
        case .not: "Not"
        case .compare: "Compare"
        case .between: "Between"
        case .time: "Time"
        case .days: "Days"
        }
    }
    var body: some View {
        Form {
            Picker("Match", selection: Binding(get: { kind }, set: changeKind)) {
                ForEach(["All", "Any", "Not", "Compare", "Between", "Time", "Days"], id: \.self) { Text($0) }
            }
            fields
            Section { Text(condition.summary).foregroundStyle(Theme.text2) }
        }.navigationTitle("Conditions").navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private var fields: some View {
        switch condition {
        case .all(let children), .any(let children):
            ForEach(children.indices, id: \.self) { index in
                NavigationLink {
                    AnyView(AutomationConditionEditor(condition: Binding(get: { children[index] }, set: { replacement in
                        var changed = children; changed[index] = replacement; replaceChildren(changed)
                    }), depth: depth + 1))
                } label: { Text(children[index].summary) }.disabled(depth >= 16)
            }.onDelete { indices in var changed = children; changed.remove(atOffsets: indices); replaceChildren(changed) }
            Button("Add condition") { replaceChildren(children + [.compare(operation: ">", left: .signal("ambient.temperature"), right: .literal(76))]) }
                .disabled(children.count >= 24 || depth >= 16)
            Text(kind == "All" ? "All conditions must match. An empty list always matches." : "At least one condition must match. An empty list never matches.").font(.footnote).foregroundStyle(Theme.text2)
        case .not(let child):
            NavigationLink { AnyView(AutomationConditionEditor(condition: Binding(get: { child }, set: { condition = .not($0) }), depth: depth + 1)) } label: { Text(child.summary) }.disabled(depth >= 16)
        case .compare(let operation, let left, let right):
            expression("Observed", Binding(get: { left }, set: { condition = .compare(operation: operation, left: $0, right: right) }))
            Picker("Comparison", selection: Binding(get: { operation }, set: { condition = .compare(operation: $0, left: left, right: right) })) {
                ForEach([">", ">=", "<", "<=", "==", "!="], id: \.self) { Text($0) }
            }
            expression("Threshold", Binding(get: { right }, set: { condition = .compare(operation: operation, left: left, right: $0) }))
        case .between(let subject, let minimum, let maximum):
            expression("Observed", Binding(get: { subject }, set: { condition = .between(subject: $0, minimum: minimum, maximum: maximum) }))
            expression("Minimum", Binding(get: { minimum }, set: { condition = .between(subject: subject, minimum: $0, maximum: maximum) }))
            expression("Maximum", Binding(get: { maximum }, set: { condition = .between(subject: subject, minimum: minimum, maximum: $0) }))
        case .time(let start, let end):
            TextField("Start, HH:mm", text: Binding(get: { start }, set: { condition = .time(start: $0, end: end) })).accessibilityIdentifier("automation.time.start").keyboardType(.numbersAndPunctuation)
            TextField("End, HH:mm", text: Binding(get: { end }, set: { condition = .time(start: start, end: $0) })).accessibilityIdentifier("automation.time.end").keyboardType(.numbersAndPunctuation)
            Text("Uses the Pod’s timezone. An end before the start crosses midnight.").font(.footnote).foregroundStyle(Theme.text2)
        case .days(let days):
            AutomationDayPicker(days: Binding(get: { days }, set: { condition = .days($0) }))
        }
    }
    private func expression(_ title: String, _ binding: Binding<AutomationExpression>) -> some View {
        NavigationLink { AutomationExpressionEditor(expression: binding, depth: depth + 1) } label: {
            VStack(alignment: .leading, spacing: 4) { Text(title); Text(binding.wrappedValue.summary).font(.footnote).foregroundStyle(Theme.text2) }
        }.disabled(depth >= 16)
    }
    private func replaceChildren(_ children: [AutomationCondition]) { condition = kind == "Any" ? .any(children) : .all(children) }
    private func changeKind(_ kind: String) {
        guard kind != self.kind else { return }
        switch kind {
        case "Any": condition = .any([])
        case "Not": condition = .not(.all([]))
        case "Compare": condition = .compare(operation: ">", left: .signal("ambient.temperature"), right: .literal(76))
        case "Between": condition = .between(subject: .signal("ambient.temperature"), minimum: .literal(65), maximum: .literal(80))
        case "Time": condition = .time(start: "21:00", end: "07:00")
        case "Days": condition = .days(DayOfWeek.weekdays)
        default: condition = .all([])
        }
    }
}

struct AutomationDayPicker: View {
    @Binding var days: [DayOfWeek]
    var body: some View {
        ForEach(DayOfWeek.weekdays) { day in
            Toggle(day.displayName, isOn: Binding(get: { days.contains(day) }, set: { selected in
                if selected { if !days.contains(day) { days.append(day) } } else { days.removeAll { $0 == day } }
            }))
        }
    }
}
