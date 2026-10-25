import Charts
import SwiftUI

struct RemoteStageRulesScreen: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RemoteStageWorkspace
    @State private var pendingSide: Side?
    @State private var confirmWrite = false
    @State private var proposed: RemoteStageClassifier?
    @State private var proposalTitle = "Save stage rules?"
    @State private var reloadConfirm = false
    init(side: Side = .left) {
        _model = State(
            initialValue: RemoteStageWorkspace(
                side: side, client: APIBackend.current.isDemo ? DemoRemoteStageClient() : CoreRemoteStageClient()))
    }
    private var previewKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(model.draft).base64EncodedString()) ?? "none"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                NavigationLink("Pod model library") { RemoteStageModelsScreen(side: model.side) }
                    .accessibilityIdentifier("stage.openModels")
                if model.loading { ProgressView("Loading stage rules…") }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(Theme.amber).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                if let state = model.state, model.draft != nil {
                    status(state)
                    editor(state).disabled(model.saving || model.loading)
                    previewCard
                    history(state)
                } else if !model.loading {
                    Button("Retry") { Task { await model.load() } }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Pod sleep stages").navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .task(id: "\(model.side.rawValue)-\(model.nights)-\(previewKey)") {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                await model.updatePreview()
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await model.refreshAcknowledgement()
                }
            }
            .confirmationDialog(
                "Discard this draft and change sides?",
                isPresented: Binding(get: { pendingSide != nil }, set: { if !$0 { pendingSide = nil } }),
                titleVisibility: .visible
            ) {
                if let selected = pendingSide {
                    Button("Discard and switch", role: .destructive) {
                        pendingSide = nil
                        Task { await model.load(side: selected) }
                    }
                }
            }
            .confirmationDialog(proposalTitle, isPresented: $confirmWrite, titleVisibility: .visible) {
                Button("Save for \(settings.sideName(for: model.side))") {
                    let candidate = proposed
                    Task { _ = await model.save(candidate) }
                }
            } message: {
                Text(
                    "The controller will use these rules for this side. Past nights are re-scored after the processor adopts the change. This does not alter this iPhone’s local analysis settings or existing Apple Health entries."
                )
            }
            .confirmationDialog(
                "Discard your draft and reload?", isPresented: $reloadConfirm, titleVisibility: .visible
            ) {
                Button("Discard and reload", role: .destructive) { Task { await model.load() } }
            }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Stage rules side",
                selection: Binding(
                    get: { model.side },
                    set: { side in
                        if model.dirty { pendingSide = side } else { Task { await model.load(side: side) } }
                    })
            ) { ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) } }.pickerStyle(.segmented).disabled(
                model.saving)
            Text(
                "These rules run on your Pod. The first matching rule assigns each five-minute epoch; missing signals never match a condition."
            )
            .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if APIBackend.current.isDemo {
                Text("Demo · changes stay in memory. No live processor or reference-night preview.").font(.footnote)
                    .foregroundStyle(Theme.text2)
            }
            Button("Reload rules", systemImage: "arrow.clockwise") {
                if model.dirty { reloadConfirm = true } else { Task { await model.load() } }
            }.disabled(model.saving || model.loading)
        }
    }
    private func status(_ state: RemoteStageState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.isDefault ? "System defaults" : "Custom rules").font(.headline)
            if model.dirty { Text("Unsaved draft").foregroundStyle(Theme.amber) }
            if let pending = state.pending {
                Text(
                    "Saved change \(pending.generation) is waiting for processor adoption. Displayed nights still use the acknowledged rules."
                ).foregroundStyle(Theme.amber)
            }
            if let warning = state.pending?.warning ?? state.provenance?.warning {
                Text(warning).foregroundStyle(Theme.amber)
            }
            if let provenance = state.provenance {
                Text("Source: \(provenance.source)\(provenance.generation.map { " · generation \($0)" } ?? "")")
                    .foregroundStyle(Theme.text2)
            }
            Menu("Start from preset") {
                ForEach(state.presets) { preset in Button(preset.label) { model.draft = preset.classifier } }
            }.disabled(model.saving)
            Button("Reset to default", role: .destructive) {
                propose(nil, title: "Restore the Pod’s default stage rules?")
            }.disabled((state.isDefault && state.pending == nil) || model.saving)
        }.font(.footnote).cardStyle()
    }
    private func editor(_ state: RemoteStageState) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            quickAdjust
            ruleList(lowSignal: false)
            signalLimits
            ruleList(lowSignal: true)
            cleanup
            if let validation = model.draft?.validation {
                Text(validation).font(.footnote).foregroundStyle(Theme.amber)
            }
        }
    }
    @ViewBuilder private var quickAdjust: some View {
        if let ruleset = model.draft?.ruleset {
            VStack(alignment: .leading, spacing: 16) {
                Text("Quick adjust").font(.headline)
                if let target = ruleset.quickCondition(stage: .wake, metric: .movement) {
                    quickSlider("Wake sensitivity", target: target, range: 0...400, step: 5)
                }
                if let target = ruleset.quickCondition(stage: .deep, metric: .hrRatio) {
                    quickSlider("Deep sleep HR ratio", target: target, range: 0.8...1, step: 0.005)
                }
                Text("Adjusts the matching threshold in the rules below.").font(.footnote).foregroundStyle(Theme.text2)
            }.cardStyle()
        }
    }
    private func quickSlider(
        _ title: String, target: (rule: Int, condition: Int), range: ClosedRange<Double>, step: Double
    ) -> some View {
        let value = Binding(
            get: {
                guard let rules = model.draft?.ruleset.rules, rules.indices.contains(target.rule),
                    rules[target.rule].when.indices.contains(target.condition)
                else { return range.lowerBound }
                return rules[target.rule].when[target.condition].value
            },
            set: {
                guard let rules = model.draft?.ruleset.rules, rules.indices.contains(target.rule),
                    rules[target.rule].when.indices.contains(target.condition)
                else { return }
                model.draft?.ruleset.rules[target.rule].when[target.condition].value = $0
            })
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(value.wrappedValue.formatted(.number.precision(.fractionLength(0...3))))").font(
                .subheadline)
            Slider(
                value: Binding(
                    get: {
                        min(
                            range.upperBound,
                            max(range.lowerBound, value.wrappedValue.isFinite ? value.wrappedValue : range.lowerBound))
                    }, set: { value.wrappedValue = $0 }), in: range, step: step
            ).accessibilityLabel(title)
        }
    }
    private func rules(_ lowSignal: Bool) -> Binding<[RemoteStageRule]> {
        Binding(
            get: { lowSignal ? model.draft?.ruleset.lowSignalRules ?? [] : model.draft?.ruleset.rules ?? [] },
            set: {
                if lowSignal { model.draft?.ruleset.lowSignalRules = $0 } else { model.draft?.ruleset.rules = $0 }
            })
    }
    private func ruleList(lowSignal: Bool) -> some View {
        let list = rules(lowSignal)
        let stats =
            model.previewIsCurrent
            ? (lowSignal ? model.preview?.candidate?.stats?.lowSignalRules : model.preview?.candidate?.stats?.rules)
            : nil
        return VStack(alignment: .leading, spacing: 14) {
            Text(lowSignal ? "Low-signal rules" : "Stage rules").font(.headline)
            if lowSignal {
                number("Use below calibration quality", value: field(\.lowSignalBelow))
                if let count = model.preview?.candidate?.stats?.lowSignalNights {
                    Text("Used on \(count) preview nights").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            ForEach(Array(list.wrappedValue.enumerated()), id: \.element.id) { index, rule in
                RemoteStageRuleRow(
                    rule: Binding(
                        get: { list.wrappedValue.first { $0.id == rule.id } ?? rule },
                        set: {
                            if let current = list.wrappedValue.firstIndex(where: { $0.id == rule.id }) {
                                list.wrappedValue[current] = $0
                            }
                        }),
                    index: index, count: list.wrappedValue.count, prefix: lowSignal ? "Low-signal rule" : "Rule",
                    hitCount: stats?.hits.indices.contains(index) == true ? stats?.hits[index] : nil,
                    epochs: stats?.epochs,
                    shadowedBy: stats?.shadowedBy.indices.contains(index) == true ? stats?.shadowedBy[index] : nil,
                    move: { destination in
                        var value = list.wrappedValue
                        guard value.indices.contains(index), value.indices.contains(destination) else { return }
                        value.swapAt(index, destination)
                        list.wrappedValue = value
                    },
                    remove: { if list.wrappedValue.indices.contains(index) { list.wrappedValue.remove(at: index) } })
                if index != list.wrappedValue.indices.last { Divider() }
            }
            if let stats {
                Text("Fallback: \(stats.fallbackHits) of \(stats.epochs) epochs").font(.footnote).foregroundStyle(
                    Theme.text2)
            }
            Button(lowSignal ? "Add low-signal rule" : "Add rule", systemImage: "plus") {
                list.wrappedValue.append(.init(stage: .light, when: [.init(metric: .movement, op: .less, value: 30)]))
            }.disabled(list.wrappedValue.count >= 32).accessibilityIdentifier(
                lowSignal ? "stage.addLowRule" : "stage.addRule")
            if !lowSignal {
                Picker("Otherwise", selection: field(\.fallback)) {
                    ForEach(RemoteSleepStage.allCases) { Text($0.title).tag($0) }
                }
            }
        }.cardStyle()
    }
    private var signalLimits: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signal limits").font(.headline)
            Text("Readings outside these limits are ignored before classification.").font(.footnote).foregroundStyle(
                Theme.text2)
            limit("Heart rate · bpm", key: \.heartRate)
            limit("HRV · ms", key: \.hrv)
            limit("Breathing · br/min", key: \.breathingRate)
            number("Heart-rate spike cutoff · standard deviations", value: field(\.outliers.heartRateSpikeStdDevs))
            if let stats = model.preview?.candidate?.stats {
                Text(
                    "Preview: \(stats.spikesDropped) spikes removed from \(stats.heartRateReadings) heart-rate readings"
                ).font(.footnote).foregroundStyle(Theme.text2)
            }
        }.cardStyle()
    }
    private func limit(_ title: String, key: WritableKeyPath<RemoteStageRuleset.Outliers, RemoteStageRange>)
        -> some View {
        DisclosureGroup(title) {
            number(
                "Minimum",
                value: Binding(
                    get: { model.draft?.ruleset.outliers[keyPath: key].min ?? 0 },
                    set: { model.draft?.ruleset.outliers[keyPath: key].min = $0 }))
            number(
                "Maximum",
                value: Binding(
                    get: { model.draft?.ruleset.outliers[keyPath: key].max ?? 0 },
                    set: { model.draft?.ruleset.outliers[keyPath: key].max = $0 }))
        }
    }
    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cleanup").font(.headline)
            Toggle("Smooth single-epoch blips", isOn: field(\.smoothIsolatedEpochs)).tint(Theme.green)
            Text("A–B–A becomes A–A–A. Transition rules run after classification.").font(.footnote).foregroundStyle(
                Theme.text2)
            if let transitions = model.draft?.ruleset.transitions {
                ForEach(Array(transitions.enumerated()), id: \.element.id) { index, transition in
                    DisclosureGroup("\(transition.from.title) → \(transition.to.title) via \(transition.via.title)") {
                        stagePicker("From", binding: transitionField(transition, path: \.from))
                        stagePicker("To", binding: transitionField(transition, path: \.to))
                        stagePicker("Through", binding: transitionField(transition, path: \.via))
                        Button("Remove transition", role: .destructive) {
                            if model.draft?.ruleset.transitions.indices.contains(index) == true {
                                model.draft?.ruleset.transitions.remove(at: index)
                            }
                        }
                    }
                }
                Button("Add transition", systemImage: "plus") {
                    model.draft?.ruleset.transitions.append(.init(from: .wake, to: .deep, via: .light))
                }.disabled(transitions.count >= 16)
            }
            if let stats = model.preview?.candidate?.stats {
                Text("Preview: \(stats.smoothed) blips smoothed · \(stats.transitionFixes) transitions adjusted").font(
                    .footnote
                ).foregroundStyle(Theme.text2)
            }
        }.cardStyle()
    }
    private func field<Value>(_ path: WritableKeyPath<RemoteStageRuleset, Value>) -> Binding<Value> {
        // Keep the render's value while an async side change removes the previous editor.
        let snapshot = model.draft!.ruleset[keyPath: path]
        return Binding(
            get: { model.draft?.ruleset[keyPath: path] ?? snapshot }, set: { model.draft?.ruleset[keyPath: path] = $0 })
    }
    private func transitionField(
        _ transition: RemoteStageTransition, path: WritableKeyPath<RemoteStageTransition, RemoteSleepStage>
    ) -> Binding<RemoteSleepStage> {
        Binding(
            get: { (model.draft?.ruleset.transitions.first { $0.id == transition.id } ?? transition)[keyPath: path] },
            set: {
                if let index = model.draft?.ruleset.transitions.firstIndex(where: { $0.id == transition.id }) {
                    model.draft?.ruleset.transitions[index][keyPath: path] = $0
                }
            })
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(Theme.text2)
            RemoteStageNumberField(title: title, value: value)
        }.padding(.vertical, 4)
    }
    private func stagePicker(_ title: String, binding: Binding<RemoteSleepStage>) -> some View {
        Picker(title, selection: binding) { ForEach(RemoteSleepStage.allCases) { Text($0.title).tag($0) } }
    }
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preview").font(.headline)
            Picker("Preview nights", selection: $model.nights) {
                Text("Last night").tag(1)
                Text("7 nights").tag(7)
            }.pickerStyle(.segmented).disabled(model.saving)
            if model.previewing { ProgressView("Updating preview…") }
            if model.preview != nil && !model.previewIsCurrent {
                Text("Preview updating for your current draft…").foregroundStyle(Theme.text2)
            }
            if let error = model.previewError {
                Text(error).foregroundStyle(Theme.amber)
                Button("Retry preview") { Task { await model.updatePreview() } }
            }
            if let preview = model.preview, model.previewIsCurrent {
                if let saved = preview.saved { summary("Saved", saved) }
                if let candidate = preview.candidate { summary("These rules", candidate) }
                if preview.saved == nil && preview.candidate == nil {
                    Text("No night with vitals to preview.").foregroundStyle(Theme.text2)
                }
                if let changed = preview.changed {
                    Text("\(changed.changed) of \(changed.total) epochs change").monospacedDigit()
                    if let start = preview.enteredBedAt, let end = preview.leftBedAt, end > start {
                        Chart(Array(changed.segments.enumerated()), id: \.offset) { _, segment in
                            RectangleMark(
                                xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
                                yStart: .value("Lane", 0), yEnd: .value("Lane", 1)
                            ).foregroundStyle(Theme.cool)
                        }.chartXScale(domain: start...end).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 12)
                            .accessibilityLabel("Changed epochs across the latest night")
                    }
                }
                if !preview.hasReference {
                    Text("Import Watch sleep stages to compare agreement.").foregroundStyle(Theme.text2)
                }
            }
            Button("Save rules", systemImage: "checkmark") { propose(model.draft, title: "Save stage rules?") }
                .disabled(!model.canSave).accessibilityIdentifier("stage.saveRules")
            Button("Discard draft") { model.discard() }.disabled(!model.dirty || model.saving)
        }.font(.footnote).cardStyle()
    }
    private func summary(_ title: String, _ summary: RemoteStagePreview.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · quality \(Int(summary.qualityScore.rounded()))").font(.subheadline.bold())
            Chart(RemoteSleepStage.allCases) { stage in
                BarMark(x: .value("Percent", summary.distribution[stage.rawValue] ?? 0), y: .value("Stages", title))
                    .foregroundStyle(stageColor(stage))
            }.chartXScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 16).clipShape(
                Capsule()
            ).accessibilityHidden(true)
            ForEach(RemoteSleepStage.allCases) { stage in
                Text(
                    "\(stage.title): \(Int((summary.durations[stage.rawValue] ?? 0) / 60000)) min · \(Int(summary.distribution[stage.rawValue] ?? 0))%"
                )
            }
            if let agreement = summary.agreement {
                Text(
                    "Watch agreement \(Int(agreement.accuracy * 100))%\(agreement.kappa.map { " · κ " + String(format: "%.2f", $0) } ?? "")"
                ).foregroundStyle(Theme.text2)
            }
            if let agreement = summary.agreement, agreement.recall != nil || agreement.confusion != nil {
                DisclosureGroup("Watch agreement details") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let epochs = agreement.epochs { Text("\(epochs) reference epochs compared") }
                        ForEach(RemoteSleepStage.allCases) { stage in
                            let recall = agreement.recall?[stage.rawValue] ?? nil
                            Text("\(stage.title) recall: \(recall.map { Int($0 * 100).description + "%" } ?? "—")")
                            if let row = agreement.confusion?[stage.rawValue] {
                                Text(
                                    "Watch \(stage.title): "
                                        + RemoteSleepStage.allCases.map {
                                            "Pod \($0.title) \(Int(row[$0.rawValue] ?? 0))"
                                        }.joined(separator: " · ")
                                )
                                .font(.caption).foregroundStyle(Theme.text2).fixedSize(
                                    horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
            if let ranges = summary.stats?.metricRanges {
                DisclosureGroup("Observed signal ranges") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(RemoteStageMetric.allCases) { metric in
                            if let range = ranges[metric.rawValue] ?? nil {
                                Text(
                                    "\(metric.title): \(range.min.formatted(.number.precision(.fractionLength(0...3))))–\(range.max.formatted(.number.precision(.fractionLength(0...3)))) \(metric.unit)"
                                )
                            } else {
                                Text("\(metric.title): no signal")
                            }
                        }
                    }.foregroundStyle(Theme.text2).padding(.top, 8)
                }
            }
        }
    }
    private func history(_ state: RemoteStageState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Changes").font(.headline)
            if state.changes.isEmpty { Text("No saved changes yet.").foregroundStyle(Theme.text2) }
            ForEach(state.changes) { change in
                VStack(alignment: .leading, spacing: 8) {
                    Text(change.summary).font(.subheadline)
                    Text(
                        Date(timeIntervalSince1970: change.changedAt / 1000),
                        format: Date.FormatStyle(
                            date: .abbreviated, time: .shortened,
                            timeZone: SleepCalendar.calendar(timeZone: settings.timeZone).timeZone)
                    ).foregroundStyle(Theme.text2)
                    if let before = change.agreementBefore, let after = change.agreementAfter {
                        Text("Watch agreement: \(Int(before * 100))% → \(Int(after * 100))%")
                    }
                    Button("Revert this change") {
                        propose(change.before, title: "Restore the rules before this change?")
                    }.disabled(model.saving)
                }
            }
        }.font(.footnote).cardStyle()
    }
    private func propose(_ classifier: RemoteStageClassifier?, title: String) {
        proposed = classifier
        proposalTitle = title
        confirmWrite = true
    }
    private func stageColor(_ stage: RemoteSleepStage) -> Color {
        switch stage {
        case .wake: Theme.amber
        case .light: Theme.cool
        case .deep: .indigo
        case .rem: .purple
        }
    }
}

private struct RemoteStageRuleRow: View {
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
private struct RemoteStageNumberField: View {
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
        .accessibilityLabel(title)
        .onChange(of: text) { value = (try? Double(text, format: .number)) ?? .nan }
        .onChange(of: value) { if !focused && value.isFinite { text = value.formatted(.number.grouping(.never)) } }
    }
}
