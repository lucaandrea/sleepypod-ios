import SwiftUI

struct AutomationEditSession: Identifiable {
    let id = UUID()
    let original: AutomationRule?
    var definition: AutomationDefinition
}

struct AutomationRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var workspace: AutomationWorkspace
    @State private var original: AutomationRule?
    @State private var draft: AutomationDefinition
    @State private var confirmDiscard = false
    @State private var confirmActive = false
    @State private var initial: AutomationDefinition
    @State private var confirmReload = false
    @FocusState private var nameFocused: Bool
    init(session: AutomationEditSession, workspace: AutomationWorkspace) {
        self.workspace = workspace; _original = State(initialValue: session.original); _initial = State(initialValue: session.definition)
        _draft = State(initialValue: session.definition)
    }
    var body: some View {
        ScrollViewReader { proxy in
            form.onChange(of: workspace.error) {
                if workspace.error != nil { withAnimation { proxy.scrollTo("automation.saveStatus", anchor: .top) } }
            }
            .onChange(of: workspace.recoveredCreation?.id) {
                if original == nil, let saved = workspace.recoveredCreation {
                    original = saved; initial = saved.definition
                    withAnimation { proxy.scrollTo("automation.nameField", anchor: .top) }
                }
            }
        }
        .disabled(workspace.saving)
        .navigationTitle(original == nil ? "New automation" : "Edit automation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if draft != initial { confirmDiscard = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { if draft.mode == .active { confirmActive = true } else { save() } }
                    .disabled(draft.validation != nil || workspace.saving || workspace.loading || !workspace.ready || (original == nil && !workspace.canCreate)).accessibilityIdentifier("automation.save")
            }
        }
        .interactiveDismissDisabled(draft != initial || workspace.saving)
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
        .confirmationDialog("Discard your draft and reload this rule?", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("Discard and reload", role: .destructive) {
                Task {
                    await workspace.load()
                    if let current = workspace.rules.first(where: { $0.id == original?.id }), workspace.ready {
                        original = current; draft = current.definition; initial = current.definition
                    } else if workspace.ready { workspace.error = "This rule no longer exists. Your draft is still available." }
                }
            }
        }
        .confirmationDialog("Save an active automation?", isPresented: $confirmActive, titleVisibility: .visible) {
            Button("Save active automation") { save() }
        } message: { Text("\(draft.name) can send its actions to \(draft.side?.rawValue ?? "both sides") while Autopilot is enabled.") }
    }
    private var form: some View {
        Form {
            if let error = workspace.error {
                Section("Save status") {
                    Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("automation.saveError")
                    if workspace.requiresReload || original == nil {
                        Button("Check saved automations") { Task { await workspace.load() } }.accessibilityIdentifier("automation.readback")
                    }
                    if original != nil { Button("Reload current rule") { confirmReload = true } }
                }.id("automation.saveStatus")
            }
            if let notice = workspace.notice { Section { Text(notice).font(.footnote).foregroundStyle(Theme.text2) } }
            Section("Automation") {
                TextField("Name", text: $draft.name).focused($nameFocused).accessibilityIdentifier("automation.name")
                    .id("automation.nameField")
                Picker("Side", selection: $draft.side) {
                    Text("Both").tag(Side?.none); Text("Left").tag(Side?.some(.left)); Text("Right").tag(Side?.some(.right))
                }
                Picker("Mode", selection: $draft.mode) { ForEach(AutomationMode.allCases) { Text($0.rawValue).tag($0) } }
                Text(draft.mode == .dryRun ? "Evaluates and logs without sending commands to the bed." : draft.mode == .off ? "This rule will not evaluate." : "Can send actions while Autopilot is enabled.").font(.footnote).foregroundStyle(Theme.text2)
            }
            trigger
            Section("If") {
                NavigationLink { AutomationConditionEditor(condition: $draft.conditions) } label: {
                    VStack(alignment: .leading, spacing: 5) { Text("Conditions"); Text(draft.conditions.summary).font(.footnote).foregroundStyle(Theme.text2) }
                }.accessibilityIdentifier("automation.conditions")
            }
            Section("Then") {
                ForEach(draft.actions.indices, id: \.self) { index in
                    NavigationLink { AutomationActionEditor(action: $draft.actions[index]) } label: { Text(draft.actions[index].summary) }
                }.onDelete { draft.actions.remove(atOffsets: $0) }
                Button("Add action") { draft.actions.append(.init(kind: .notify, message: "Automation matched")) }.disabled(draft.actions.count >= 10)
            }
            Section("Timing and priority") {
                Toggle("Cooldown", isOn: Binding(get: { draft.cooldownMin != nil }, set: { draft.cooldownMin = $0 ? 30 : nil }))
                if let cooldown = draft.cooldownMin {
                    Stepper("\(cooldown) minutes", value: Binding(get: { cooldown }, set: { draft.cooldownMin = $0 }), in: 0...1440)
                }
                TextField("Priority", value: $draft.priority, format: .number).keyboardType(.numberPad)
                Text("Higher priority rules appear first (0–1000). Equal priorities use creation order.").font(.footnote).foregroundStyle(Theme.text2)
            }
            if draft.conditions.signals.union(draft.actions.reduce(into: Set<String>()) { if let temp = $1.temp { $0.formUnion(temp.signals) } }).contains(where: { $0.contains(".cap.") }) {
                Section { AutomationLiveZones(side: draft.side) }
            }
            Section("Review") {
                Text("\(draft.trigger.summary). If \(draft.conditions.summary), \(draft.actions.map(\.summary).joined(separator: "; ")).").fixedSize(horizontal: false, vertical: true)
                NavigationLink { AutomationBacktestScreen(definition: draft, client: workspace.client) } label: { Label("Backtest this draft", systemImage: "clock.arrow.circlepath") }
                    .disabled(draft.validation != nil).accessibilityIdentifier("automation.backtest")
                NavigationLink { AutomationRangeScreen(definition: draft, client: workspace.client) } label: { Label("Replay recent nights", systemImage: "calendar") }
                    .disabled(draft.validation != nil).accessibilityIdentifier("automation.range")
                if let validation = draft.validation { Text(validation).foregroundStyle(Theme.amber) }
            }
        }.accessibilityIdentifier("automation.editor")
    }
    private var trigger: some View {
        Section("When") {
            Picker("Trigger", selection: Binding(get: { draft.trigger.kind }, set: { kind in
                switch kind {
                case .tick: draft.trigger = .init()
                case .signalChange: draft.trigger = .init(kind: kind, everyMin: nil, signal: "ambient.temperature")
                case .timeOfDay: draft.trigger = .init(kind: kind, everyMin: nil, at: "21:00")
                }
            })) {
                Text("Periodic check").tag(AutomationTrigger.Kind.tick)
                Text("Signal changes").tag(AutomationTrigger.Kind.signalChange)
                Text("Time of day").tag(AutomationTrigger.Kind.timeOfDay)
            }
            switch draft.trigger.kind {
            case .tick:
                Stepper("Every \(draft.trigger.everyMin ?? 1) \(draft.trigger.everyMin == 1 ? "minute" : "minutes")", value: Binding(get: { draft.trigger.everyMin ?? 1 }, set: { draft.trigger.everyMin = $0 }), in: 1...1440)
            case .signalChange:
                AutomationSignalPicker(signal: Binding(get: { draft.trigger.signal ?? "" }, set: { draft.trigger.signal = $0 }))
            case .timeOfDay:
                TextField("Time, HH:mm", text: Binding(get: { draft.trigger.at ?? "" }, set: { draft.trigger.at = $0 })).keyboardType(.numbersAndPunctuation)
                Toggle("Limit to selected days", isOn: Binding(get: { draft.trigger.days != nil }, set: { draft.trigger.days = $0 ? DayOfWeek.weekdays : nil }))
                if draft.trigger.days != nil { AutomationDayPicker(days: Binding(get: { draft.trigger.days ?? [] }, set: { draft.trigger.days = $0 })) }
                Text("Uses the Pod’s timezone.").font(.footnote).foregroundStyle(Theme.text2)
            }
        }
    }
    private func save() {
        nameFocused = false
        Task { if await workspace.save(draft, original: original) { dismiss() } }
    }
}
