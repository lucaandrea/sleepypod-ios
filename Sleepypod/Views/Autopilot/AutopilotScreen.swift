import SwiftUI
import FreeSleepKit

struct AutopilotScreen: View {
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedules
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: AutomationWorkspace
    @State private var editor: AutomationEditSession?
    @State private var deleting: AutomationRule?
    @State private var activating: AutomationRule?
    @State private var enableConfirm = false
    @State private var page = "Automations"
    init(client: (any AutomationClient)? = nil) {
        _model = State(initialValue: AutomationWorkspace(client: client ?? (APIBackend.current.isDemo ? DemoAutomationClient(scenario: DebugRoute.automationScenario) : CoreAutomationClient())))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.loading { ProgressView("Loading Autopilot…") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                Picker("View", selection: $page) { Text("Automations").tag("Automations"); Text("Diagnostics").tag("Diagnostics") }.pickerStyle(.segmented)
                NavigationLink { AutomationHistoryScreen(client: model.client) } label: { Label("Activity history", systemImage: "clock.arrow.circlepath") }
                AlertInboxLink()
                if page == "Automations" { rules; tonight }
                else { diagnostics }
                NavigationLink { PersonalComfortDestination(side: device.selectedSide.primarySide) } label: {
                    SettingsRow("Personal comfort", icon: "sparkles", chevron: true)
                }.buttonStyle(.plain)
                Button("Refresh Autopilot") { Task { await refresh() } }.disabled(model.saving || model.loading)
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Autopilot").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
            .task(id: page) { if page == "Diagnostics" { await model.loadDiagnostics() } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard editor == nil, !model.saving else { continue }
                    await refresh(userInitiated: false)
                }
            }
            .onDisappear { model.invalidate() }
            .sheet(item: $editor) { session in NavigationStack { AutomationRuleEditor(session: session, workspace: model) }.tint(Theme.text1) }
            .confirmationDialog("Enable Autopilot?", isPresented: $enableConfirm, titleVisibility: .visible) {
                Button("Enable Autopilot") { Task { await model.setGlobal(true) } }
            } message: { Text("Active rules may send commands to the bed. Dry-run rules only log their evaluations.") }
            .confirmationDialog("Delete automation and its history?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let rule = deleting { Button("Delete \(rule.definition.name)", role: .destructive) { Task { _ = await model.delete(rule); deleting = nil } } }
            }
            .confirmationDialog("Activate this automation?", isPresented: Binding(get: { activating != nil }, set: { if !$0 { activating = nil } }), titleVisibility: .visible) {
                if let rule = activating { Button("Activate \(rule.definition.name)") { Task { await model.setMode(.active, for: rule); await model.loadDiagnostics(); activating = nil } } }
            } message: { Text("It can send its actions to the bed while Autopilot is enabled.") }
    }
    private var header: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Autopilot", isOn: Binding(get: { model.globalEnabled == true }, set: { enabled in
                    if enabled { enableConfirm = true } else { Task { await model.setGlobal(false) } }
                })).disabled(!model.ready || model.saving || model.loading)
                Text(!model.ready ? "Controller state unavailable" : model.globalEnabled == true ? "Active rules can send actions. Dry-run rules only log." : "Off · rules cannot send actions.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if APIBackend.current.isDemo { Eyebrow("DEMO · NO BED COMMANDS", color: Theme.amber) }
                if model.requiresReload { Button("Reload controller state") { Task { await refresh() } }.accessibilityIdentifier("automation.reload") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private var ruleHeadingLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
    }
    private var rules: some View {
        VStack(alignment: .leading, spacing: 14) {
            ruleHeadingLayout { Text("Automations").font(.title3.bold()); if !typeSize.isAccessibilitySize { Spacer() }; Button { model.error = nil; editor = .init(original: nil, definition: .init(side: device.selectedSide.primarySide)) } label: { Label("New", systemImage: "plus") }.accessibilityIdentifier("automation.new").disabled(!model.canCreate || model.saving) }
            if model.ready, model.rules.isEmpty { Text("Create a rule to respond to your room or bed conditions.").foregroundStyle(Theme.text2) }
            if let error = model.summariesError { Text("Replay summaries: \(error)").font(.footnote).foregroundStyle(Theme.amber) }
            ForEach(model.rules) { rule in
                GroupedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Button { model.error = nil; editor = .init(original: rule, definition: rule.definition) } label: {
                                VStack(alignment: .leading, spacing: 4) { Text(rule.definition.name).font(.headline); Text("\(rule.definition.side?.rawValue.capitalized ?? "Both sides") · priority \(rule.definition.priority)").font(.caption).foregroundStyle(Theme.text2) }
                            }.buttonStyle(.plain).accessibilityIdentifier("automation.edit.\(rule.id)")
                            Spacer(minLength: 4)
                            Menu {
                                Button("Duplicate", systemImage: "doc.on.doc") {
                                    var copy = rule.definition; copy.name = String(copy.name.prefix(115)) + " copy"; copy.mode = .off
                                    editor = .init(original: nil, definition: copy)
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = rule }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Options for \(rule.definition.name)")
                        }
                        Text("\(rule.definition.trigger.summary) · \(rule.definition.conditions.summary)").font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(rule.definition.actions.enumerated()), id: \.offset) { _, action in Text(action.summary).font(.footnote).fixedSize(horizontal: false, vertical: true) }
                        if let summary = model.summaries.first(where: { $0.id == rule.id }) {
                            Text(summary.headline + " · last 5 nights").font(.caption).foregroundStyle(Theme.text2)
                        }
                        Picker("Mode for \(rule.definition.name)", selection: Binding(get: { rule.definition.mode }, set: { mode in
                            if mode == .active { activating = rule } else { Task { await model.setMode(mode, for: rule) } }
                        })) { ForEach(AutomationMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.disabled(!model.ready || model.saving || model.loading)
            }
        }
    }
    private var tonight: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tonight").font(.title3.bold())
            if let error = schedules.error { Text("Schedule: \(error)").font(.footnote).foregroundStyle(Theme.amber) }
            if let error = model.timelineError { Text("Recorded firings: \(error)").font(.footnote).foregroundStyle(Theme.amber) }
            AutomationTonightTimeline(timeline: AutomationTimeline(schedules: schedules.error == nil ? schedules.schedules : nil, rules: model.ready ? model.rules : [], timezone: settings.timeZone, now: model.tonight.map { Date(timeIntervalSince1970: $0.now / 1000) } ?? .now), snapshot: model.tonight, activity: model.timelineActivity, enabled: model.ready ? model.globalEnabled : nil)
            if let error = model.tonightError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            if let snapshot = model.tonight {
                ForEach(Side.allCases) { side in
                    let state = side == .left ? snapshot.sides.left : snapshot.sides.right
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(settings.sideName(for: side)).font(.headline)
                            Text(ownerLabel(state.control)).foregroundStyle(Theme.text2)
                            if let hold = state.hold { Text("Manual hold · \(hold.temperature.formatted())°F until \(AutomationDates.label(hold.expiresAt, timeZone: settings.timeZone))").font(.footnote) }
                            if let expiry = state.runOnceUntil { Text("Run-once until \(AutomationDates.label(expiry, timeZone: settings.timeZone))").font(.footnote) }
                            if let last = state.lastAutopilot {
                                Text("Last sent: \(last.ruleName) · \(last.temp.formatted())°F at \(AutomationDates.label(last.at, timeZone: settings.timeZone))").font(.footnote)
                            } else { Text("No recent Autopilot temperature command.").font(.footnote).foregroundStyle(Theme.text2) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Evaluations").font(.title3.bold())
            if APIBackend.current.isDemo, DebugRoute.automationScenario == "diagnostics" {
                Eyebrow("SYNTHETIC EVALUATION LOG", color: Theme.amber)
            }
            Text("Signals below are a live snapshot. They are not the values observed during earlier evaluations.").font(.footnote).foregroundStyle(Theme.text2)
            if let error = model.diagnosticsError { Text(error).foregroundStyle(Theme.amber) }
            GroupedCard { AutomationLiveZones(side: nil).padding(16) }
            if let snapshot = model.diagnostics {
                Text("Snapshot: \(AutomationDates.parse(snapshot.now).map { AutomationDates.label($0.timeIntervalSince1970 * 1000, timeZone: settings.timeZone, includeDate: true) } ?? snapshot.now) · \(settings.timeZone)").font(.caption).foregroundStyle(Theme.text2)
                if let now = AutomationDates.parse(snapshot.now), let start = AutomationDates.parse(snapshot.startOfDay) {
                    ForEach(snapshot.rules) { item in
                        let log = AutomationEvaluationLog(runs: item.runs, trigger: item.rule.definition.trigger,
                            now: now.timeIntervalSince1970 * 1000, startOfDay: start.timeIntervalSince1970 * 1000,
                            expectMissing: snapshot.globalEnabled && item.rule.definition.enabled)
                        AutomationDiagnosticCard(item: item, log: log, timeZone: settings.timeZone,
                            canEdit: model.ready && !model.saving && !model.loading,
                            edit: { editor = .init(original: item.rule, definition: item.rule.definition) },
                            setMode: { mode in
                                if mode == .active { activating = item.rule }
                                else { Task { await model.setMode(mode, for: item.rule); await model.loadDiagnostics() } }
                            })
                    }
                } else { Text("The controller did not provide a readable diagnostics time window.").foregroundStyle(Theme.amber) }
            }
        }
    }
    private func ownerLabel(_ control: TemperatureControlStatus?) -> String {
        guard let control else { return "Control source unavailable" }
        return control.source == nil && control.blocked == nil ? "No active control request" : control.title
    }
    private func refresh(userInitiated: Bool = true) async {
        await model.load(userInitiated: userInitiated)
        async let diagnostics: Void = model.loadDiagnostics()
        async let tonight: Void = model.loadTonight()
        async let summaries: Void = model.loadSummaries()
        async let activity: Void = model.loadTimelineActivity(timeZone: settings.timeZone)
        async let scheduleLoad: Void = schedules.fetchSchedules()
        _ = await (diagnostics, tonight, summaries, activity, scheduleLoad)
    }
}
