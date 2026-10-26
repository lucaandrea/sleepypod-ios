import SwiftUI

struct BiometricCandidateScreen: View {
    @State private var model: BiometricCandidateWorkspace
    init(profile: BiometricProfilesWorkspace, parentID: String?) { _model = State(initialValue: BiometricCandidateWorkspace(profile: profile, parentID: parentID)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Save a candidate for evaluation. This does not change live processing.").font(.subheadline).foregroundStyle(Theme.text2)
                if model.loading { ProgressView("Loading parameter definitions…") }
                if let error = model.error { BiometricProfileError(error: error) }
                if model.manifest == nil && !model.loading { Button("Retry") { Task { await model.load() } } }
                BiometricProfilePendingCard(model: model.profile)
                if model.manifest != nil {
                    BiometricProfileIdentity(title: "Starting profile", value: model.parent?.id ?? "System defaults")
                    Text("Existing sleep-stage overrides are preserved. Removing an override follows the shipped default.").font(.footnote).foregroundStyle(Theme.text2)
                    ForEach(model.parameters) { parameter in numeric(parameter) }
                    NavigationLink("Sleep stage parameters") { BiometricCandidateStagesScreen(model: model) }.accessibilityIdentifier("candidate.stages")
                    if let validation = model.validation { BiometricProfileError(error: validation) }
                    Button("Review candidate", systemImage: "checkmark.magnifyingglass") { Task { await model.review() } }
                        .disabled(!model.editable || model.validation != nil).accessibilityIdentifier("candidate.review")
                    if model.reviewing { ProgressView("Resolving candidate…") }
                    if let resolution = model.resolution {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Schema checks passed").font(.headline)
                            Text("Agreement with reference measurements has not been evaluated.").font(.footnote).foregroundStyle(Theme.text2)
                            BiometricProfileIdentity(title: "Candidate configuration hash", value: resolution.hash)
                            DisclosureGroup("Reviewed overrides") {
                                ForEach(resolution.overrides) { item in BiometricProfileIdentity(title: item.path, value: item.value.formattedJSON) }
                            }
                            Button("Save candidate without applying") { Task { await model.save() } }
                                .buttonStyle(.borderedProminent).disabled(!model.editable).accessibilityIdentifier("candidate.save")
                        }.cardStyle()
                    }
                    if let saved = model.saved {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Candidate saved").font(.headline)
                            BiometricProfileIdentity(title: "Revision", value: saved.id)
                            NavigationLink("Inspect saved candidate") { BiometricProfileReviewScreen(model: model.profile, action: .activate, target: saved.id) }.accessibilityIdentifier("candidate.inspectSaved")
                        }.cardStyle()
                    }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Candidate parameters").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("candidate.content").task { await model.load() }
    }
    private func numeric(_ parameter: BiometricProfileManifest.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(BiometricProfileLabels.component(parameter.path.components(separatedBy: ".")[0])).font(.caption).foregroundStyle(Theme.text2)
            Text(parameter.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            RemoteStageNumberField(title: parameter.title, value: Binding(get: { model.number(parameter.path) }, set: { model.setNumber(parameter.path, value: $0) }))
                .accessibilityIdentifier("candidate.number.\(parameter.path)")
            Text(parameter.description).font(.footnote).foregroundStyle(Theme.text2)
            Text("\(parameter.unit) · range \(parameter.minimum.formatted())–\(parameter.maximum.formatted())\nDefault \(parameter.defaultValue.formatted()) · original \(model.original(parameter).formatted())").font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Text(model.numeric[parameter.path] == nil ? "Inherited default" : "Overridden").font(.caption)
            if model.numeric[parameter.path] != nil { Button("Remove override") { model.setNumber(parameter.path, value: nil) }.font(.footnote) }
        }.disabled(!model.editable).cardStyle()
    }
}

struct BiometricCandidateStagesScreen: View {
    let model: BiometricCandidateWorkspace
    var body: some View {
        ScrollView {
            if let ruleset = model.stage {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Stage changes stay in this candidate. The first matching rule assigns each epoch; missing signals never match a condition.").font(.footnote).foregroundStyle(Theme.text2)
                    ruleList(ruleset, low: false)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Signal limits").font(.headline)
                        limit("Heart rate", key: \.outliers.heartRate, path: "outliers.heartRate", snapshot: ruleset)
                        limit("HRV index", key: \.outliers.hrv, path: "outliers.hrv", snapshot: ruleset)
                        limit("Breathing rate", key: \.outliers.breathingRate, path: "outliers.breathingRate", snapshot: ruleset)
                        number("HR spike standard deviations", binding: field(\.outliers.heartRateSpikeStdDevs, path: "outliers.heartRateSpikeStdDevs", snapshot: ruleset))
                        remove("outliers.heartRateSpikeStdDevs")
                        number("Low-signal quality (0–1)", binding: field(\.lowSignalBelow, path: "lowSignalBelow", snapshot: ruleset))
                        remove("lowSignalBelow")
                    }.cardStyle()
                    ruleList(ruleset, low: true)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Fallback and cleanup").font(.headline)
                        SettingsChoiceMenu(title: "Fallback stage", selection: Binding(get: { (model.stage ?? ruleset).fallback.rawValue }, set: { var next = model.stage ?? ruleset; next.fallback = RemoteSleepStage(rawValue: $0) ?? .light; model.setStage(next, path: "fallback") }), options: RemoteSleepStage.allCases.map { ($0.rawValue, $0.title) }, identifier: "candidate.fallback")
                        remove("fallback")
                        BridgeToggleRow(title: "Smooth isolated epochs", value: field(\.smoothIsolatedEpochs, path: "smoothIsolatedEpochs", snapshot: ruleset), identifier: "candidate.smooth")
                        remove("smoothIsolatedEpochs")
                        ForEach(ruleset.transitions) { transition in
                            VStack(alignment: .leading, spacing: 8) {
                                transitionPicker("From", transition: transition, key: \.from, snapshot: ruleset)
                                transitionPicker("To", transition: transition, key: \.to, snapshot: ruleset)
                                transitionPicker("Via", transition: transition, key: \.via, snapshot: ruleset)
                                Button("Remove transition", role: .destructive) { var next = model.stage ?? ruleset; next.transitions.removeAll { $0.id == transition.id }; model.setStage(next, path: "transitions") }
                            }.padding(.vertical, 6)
                        }
                        Button("Add transition", systemImage: "plus") { var next = model.stage ?? ruleset; next.transitions.append(.init(from: .deep, to: .rem, via: .light)); model.setStage(next, path: "transitions") }.disabled(ruleset.transitions.count >= 16)
                        remove("transitions")
                    }.cardStyle()
                    if let validation = model.validation { BiometricProfileError(error: validation) }
                }.disabled(!model.editable).frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
            }
        }.background(Theme.background).navigationTitle("Candidate sleep stages").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("candidate.stageContent")
    }
    private func ruleList(_ snapshot: RemoteStageRuleset, low: Bool) -> some View {
        let rules = low ? snapshot.lowSignalRules : snapshot.rules
        let path = low ? "lowSignalRules" : "rules"
        return VStack(alignment: .leading, spacing: 14) {
            Text(low ? "Low-signal rules" : "Classification rules").font(.headline)
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                RemoteStageRuleRow(rule: Binding(get: { (low ? model.stage?.lowSignalRules : model.stage?.rules)?.first { $0.id == rule.id } ?? rule }, set: { value in
                    var next = model.stage ?? snapshot
                    if low, let position = next.lowSignalRules.firstIndex(where: { $0.id == rule.id }) { next.lowSignalRules[position] = value }
                    if !low, let position = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[position] = value }
                    model.setStage(next, path: path)
                }), index: index, count: rules.count, prefix: low ? "Low-signal rule" : "Rule", hitCount: nil, epochs: nil, shadowedBy: nil, move: { destination in
                    var next = model.stage ?? snapshot; var values = low ? next.lowSignalRules : next.rules
                    guard values.indices.contains(index), values.indices.contains(destination) else { return }
                    let moved = values.remove(at: index); values.insert(moved, at: destination)
                    if low { next.lowSignalRules = values } else { next.rules = values }; model.setStage(next, path: path)
                }, remove: {
                    var next = model.stage ?? snapshot
                    if low { next.lowSignalRules.removeAll { $0.id == rule.id } } else { next.rules.removeAll { $0.id == rule.id } }
                    model.setStage(next, path: path)
                })
            }
            Button("Add rule", systemImage: "plus") {
                var next = model.stage ?? snapshot; let rule = RemoteStageRule(stage: .light, when: [.init(metric: .hrRatio, op: .less, value: 0.95)])
                if low { next.lowSignalRules.append(rule) } else { next.rules.append(rule) }; model.setStage(next, path: path)
            }.disabled(rules.count >= 32)
            remove(path)
        }.cardStyle()
    }
    private func field<Value>(_ key: WritableKeyPath<RemoteStageRuleset, Value>, path: String, snapshot: RemoteStageRuleset) -> Binding<Value> {
        Binding(get: { (model.stage ?? snapshot)[keyPath: key] }, set: { value in var next = model.stage ?? snapshot; next[keyPath: key] = value; model.setStage(next, path: path) })
    }
    private func number(_ title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.subheadline); RemoteStageNumberField(title: title, value: binding) }
    }
    private func limit(_ title: String, key: WritableKeyPath<RemoteStageRuleset, RemoteStageRange>, path: String, snapshot: RemoteStageRuleset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            number("\(title) minimum", binding: field(key.appending(path: \.min), path: "\(path).min", snapshot: snapshot)); remove("\(path).min")
            number("\(title) maximum", binding: field(key.appending(path: \.max), path: "\(path).max", snapshot: snapshot)); remove("\(path).max")
        }
    }
    @ViewBuilder private func remove(_ path: String) -> some View {
        if model.stagePaths.contains("sleep_stages.ruleset.\(path)") { Button("Remove \(path) override") { model.removeStageOverride(path) }.font(.footnote) }
    }
    private func transitionPicker(_ title: String, transition: RemoteStageTransition, key: WritableKeyPath<RemoteStageTransition, RemoteSleepStage>, snapshot: RemoteStageRuleset) -> some View {
        SettingsChoiceMenu(title: title, selection: Binding(get: { ((model.stage ?? snapshot).transitions.first { $0.id == transition.id } ?? transition)[keyPath: key].rawValue }, set: { rawValue in
            guard let value = RemoteSleepStage(rawValue: rawValue) else { return }
            var next = model.stage ?? snapshot
            if let index = next.transitions.firstIndex(where: { $0.id == transition.id }) { next.transitions[index][keyPath: key] = value; model.setStage(next, path: "transitions") }
        }), options: RemoteSleepStage.allCases.map { ($0.rawValue, $0.title) }, identifier: "candidate.transition.\(transition.id).\(title)")
    }
}
