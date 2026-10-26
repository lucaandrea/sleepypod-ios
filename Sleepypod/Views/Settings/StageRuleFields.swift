import SwiftUI

struct RemoteStageRuleRow: View {
    @Binding var rule: RemoteStageRule
    let index: Int
    let count: Int
    let prefix: String
    let hitCount: Int?
    let epochs: Int?
    let shadowedBy: Int?
    let move: (Int) -> Void
    let remove: () -> Void
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Assign stage").font(.caption).foregroundStyle(Theme.text2)
                Picker("Assign stage", selection: $rule.stage) {
                    ForEach(RemoteSleepStage.allCases) { Text($0.title).tag($0) }
                }
                ForEach(Array(rule.when.enumerated()), id: \.element.id) { condition, snapshot in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Condition \(condition + 1)").font(.subheadline.bold())
                        Picker("Signal", selection: conditionField(snapshot, path: \.metric)) {
                            ForEach(RemoteStageMetric.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Comparison", selection: conditionField(snapshot, path: \.op)) {
                            ForEach(RemoteStageOperator.allCases) { Text($0.title).tag($0) }
                        }
                        Text("Threshold").font(.caption).foregroundStyle(Theme.text2)
                        RemoteStageNumberField(
                            title: "\(prefix) \(index + 1) condition \(condition + 1) threshold",
                            value: conditionField(snapshot, path: \.value))
                        Button("Remove condition", role: .destructive) {
                            if rule.when.indices.contains(condition) { rule.when.remove(at: condition) }
                        }
                    }.padding(.vertical, 8)
                }
                if rule.when.isEmpty {
                    Text("Always matches. Later rules cannot run after this one.").font(.footnote).foregroundStyle(
                        Theme.amber)
                }
                Button("Add condition", systemImage: "plus") {
                    rule.when.append(.init(metric: .hrRatio, op: .less, value: 0.95))
                }.disabled(rule.when.count >= 8)
                ViewThatFits(in: .horizontal) {
                    orderButtons(vertical: false)
                    orderButtons(vertical: true)
                }
                Button("Remove rule", role: .destructive, action: remove)
            }.padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(prefix) \(index + 1)").font(.subheadline.bold())
                Text(rule.summary).font(.footnote).foregroundStyle(Theme.text2).fixedSize(
                    horizontal: false, vertical: true)
                if let hitCount, let epochs {
                    Text("\(hitCount) of \(epochs) preview epochs").font(.caption).foregroundStyle(Theme.text3)
                }
                if let shadowedBy {
                    Text("An earlier match in rule \(shadowedBy + 1) takes precedence.").font(.caption).foregroundStyle(
                        Theme.amber)
                }
            }
        }.accessibilityIdentifier("stage.\(prefix == "Rule" ? "rule" : "lowRule").\(index)")
    }
    private func conditionField<Value>(
        _ condition: RemoteStageCondition, path: WritableKeyPath<RemoteStageCondition, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (rule.when.first { $0.id == condition.id } ?? condition)[keyPath: path] },
            set: {
                if let index = rule.when.firstIndex(where: { $0.id == condition.id }) {
                    rule.when[index][keyPath: path] = $0
                }
            })
    }
    private func orderButtons(vertical: Bool) -> some View {
        let layout =
            vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            Button("Move up", systemImage: "arrow.up") { move(index - 1) }.disabled(index == 0)
            Button("Move down", systemImage: "arrow.down") { move(index + 1) }.disabled(index == count - 1)
        }
    }
}

/// Invalid text invalidates the draft instead of silently saving the previous numeric value.
struct RemoteStageNumberField: View {
    let title: String
    @Binding var value: Double
    @State private var text: String
    @FocusState private var focused: Bool
    init(title: String, value: Binding<Double>) {
        self.title = title
        _value = value
        _text = State(initialValue: value.wrappedValue.formatted(.number.grouping(.never)))
    }
    var body: some View {
        TextField(title, text: $text).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder).focused(
            $focused
        )
        .accessibilityLabel(title).submitLabel(.done).onSubmit { focused = false }
        .onChange(of: text) { value = (try? Double(text, format: .number)) ?? .nan }
        .onChange(of: value) { if !focused && value.isFinite { text = value.formatted(.number.grouping(.never)) } }
    }
}
