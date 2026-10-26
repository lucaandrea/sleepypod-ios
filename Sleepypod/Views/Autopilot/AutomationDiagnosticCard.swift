import SwiftUI

struct AutomationDiagnosticCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: AutomationDiagnostics.Rule
    let log: AutomationEvaluationLog
    let timeZone: String
    let canEdit: Bool
    let edit: () -> Void
    let setMode: @MainActor @Sendable (AutomationMode) -> Void
    @State private var filter = AutomationEvaluationFilter.all
    @State private var visibleGroups = 10
    private var groups: [AutomationEvaluationGroup] { log.groups.filter { filter.matches($0.kind) } }
    private var layout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: edit) {
                    Label(item.rule.definition.name, systemImage: "pencil").font(.headline)
                }.buttonStyle(.plain).disabled(!canEdit).accessibilityIdentifier("diagnostics.edit.\(item.id)")
                Text("\(item.rule.definition.side?.rawValue.capitalized ?? "Both sides") · \(item.rule.definition.trigger.summary)")
                    .font(.caption).foregroundStyle(Theme.text2)
                Text(item.rule.definition.conditions.summary).font(.footnote)
                ForEach(Array(item.rule.definition.actions.enumerated()), id: \.offset) { _, action in Text(action.summary).font(.footnote).foregroundStyle(Theme.text2) }
                Picker("Mode for \(item.rule.definition.name)", selection: Binding(get: { item.rule.definition.mode }, set: setMode)) {
                    ForEach(AutomationMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).disabled(!canEdit)
                statistics
                AutomationEvaluationStrip(strip: log.strip, timeZone: timeZone)
                if log.unreadableCount > 0 {
                    Text("\(log.unreadableCount) evaluations have an unreadable outcome or time and are excluded.")
                        .font(.footnote).foregroundStyle(Theme.amber)
                }
                DisclosureGroup { liveSignals } label: {
                    Text("Live signals and thresholds").multilineTextAlignment(.leading)
                }.font(.subheadline)
                Divider().overlay(Theme.border1)
                evaluationLog
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .onChange(of: filter) { visibleGroups = 10 }
        .onChange(of: item.id) { visibleGroups = 10; filter = .all }
    }
    private var statistics: some View {
        VStack(alignment: .leading, spacing: 12) {
            layout {
                metric("Last evaluated", value: log.last.map { clock($0.at) } ?? "Never", detail: item.rule.definition.trigger.summary)
                metric("Last condition", value: log.verdict?.capitalized ?? "Not evaluated", detail: "Verdict from the recorded evaluation")
            }
            layout {
                metric("Would fire today", value: String(log.wouldCount), detail: log.lastWould.map { "Last at \(clock($0.at))" } ?? "No dry runs today")
                metric("Fired / clamped today", value: String(log.firedCount), detail: "\(log.sentCount) actually sent to bed")
            }
        }
    }
    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.headline.monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(Theme.text2)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private var liveSignals: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current readings are separate from the condition verdict above. Historical signal values are not included in this log.")
                .font(.caption).foregroundStyle(Theme.text2)
            ForEach(item.signals.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(AutomationSignal.label(key)).font(.subheadline)
                    Text("Now · \(AutomationSignal.display(item.signals[key].flatMap { $0 }, key: key))")
                        .font(.footnote.monospacedDigit())
                    ForEach(Array(AutomationLiveThreshold.collect(item.rule.definition.conditions).filter { $0.signal == key }.enumerated()), id: \.offset) { _, threshold in
                        Text(thresholdLabel(threshold)).font(.caption).foregroundStyle(Theme.text2)
                    }
                }.accessibilityElement(children: .combine)
            }
            if item.signals.isEmpty { Text("This condition has no live signal readings.").font(.footnote).foregroundStyle(Theme.text2) }
        }.padding(.top, 8)
    }
    private var evaluationLog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today’s evaluations").font(.headline)
            Picker("Evaluation filter", selection: $filter) {
                ForEach(AutomationEvaluationFilter.allCases) { value in
                    Text("\(value.title) · \(log.count(value))").tag(value)
                }
            }.pickerStyle(.menu).accessibilityIdentifier("diagnostics.filter.\(item.id)")
            Text("Consecutive matching outcomes are grouped. Counts represent evaluations, not groups.")
                .font(.caption).foregroundStyle(Theme.text2)
            if groups.isEmpty { Text("No evaluations match this filter today.").font(.footnote).foregroundStyle(Theme.text2) }
            ForEach(Array(groups.prefix(visibleGroups).enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 5) {
                    Label("\(group.kind.label) · \(group.count)", systemImage: group.kind.symbol)
                        .font(.subheadline).foregroundStyle(group.kind.color)
                    Text(group.firstMs == group.lastMs ? clock(group.lastMs) : "\(clock(group.firstMs)) – \(clock(group.lastMs))")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
                    if let reason = group.reason { Text(reason == "condition-unknown" ? "Missing signal" : reason.replacingOccurrences(of: "-", with: " ")).font(.footnote) }
                    if group.sent > 0 { Text("\(group.sent) actually sent to bed").font(.caption) }
                    if group.kind == .missing {
                        Text("An expected interval has no recorded evaluation. This does not establish whether the controller was offline.")
                            .font(.caption).foregroundStyle(Theme.text2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                Divider().overlay(Theme.border1)
            }
            if groups.count > visibleGroups {
                Button("Show more evaluations") { visibleGroups += 10 }
                    .accessibilityIdentifier("diagnostics.more.\(item.id)")
            }
            Text("\(min(visibleGroups, groups.count)) of \(groups.count) groups · \(timeZone)").font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private func clock(_ milliseconds: Double) -> String { AutomationDates.label(milliseconds, timeZone: timeZone) }
    private func thresholdLabel(_ threshold: AutomationLiveThreshold) -> String {
        let window = threshold.function.map { " · \(threshold.minutes ?? 0)-minute \($0)" } ?? ""
        return "Comparison \(threshold.operation) \(AutomationSignal.display(threshold.value, key: threshold.signal))\(window)"
    }
}

extension AutomationEvaluationKind {
    var color: Color {
        switch self {
        case .fired: Theme.green
        case .would: Theme.amber
        case .error, .missing: Theme.red
        case .cooldown: Theme.text3
        case .skipped, .none: Theme.text2
        }
    }
    var symbol: String {
        switch self {
        case .fired: "checkmark.circle"
        case .would: "eye"
        case .error: "exclamationmark.triangle"
        case .missing: "questionmark.circle"
        case .cooldown: "hourglass"
        case .skipped: "forward.end"
        case .none: "minus.circle"
        }
    }
}
