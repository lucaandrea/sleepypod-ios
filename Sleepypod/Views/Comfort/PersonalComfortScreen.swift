import SwiftUI
import FreeSleepKit

struct PersonalComfortDestination: View {
    let side: Side
    var body: some View {
        if APIBackend.current == .freeSleep { PodFeatureScreen(.comfort, side: side.rawValue) }
        else { PersonalComfortScreen(side: side) }
    }
}

private struct PersonalComfortEditSession: Identifiable {
    let id = UUID()
    let original: PersonalComfortConfig
    let features: PersonalComfortStatus.Features
}
struct PersonalComfortScreen: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var phase
    @State private var model = PersonalComfortWorkspace()
    @State private var demoClient: DemoPersonalComfortClient
    @State private var side: Side
    @State private var editor: PersonalComfortEditSession?
    @State private var feedbackDate = ""
    @State private var feeling = "comfortable"
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    private var scope: String { "\(backend)|\(address)|\(host)|\(ownerRevision)|\(side.rawValue)|\(phase)" }
    init(side: Side) { _side = State(initialValue: side); _demoClient = State(initialValue: DemoPersonalComfortClient(includeExample: DebugRoute.personalComfortExample)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Personal comfort side", selection: $side) { ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) } }
                    .pickerStyle(.segmented).accessibilityIdentifier("comfort.side").disabled(model.saving)
                if APIBackend.current.isDemo { Eyebrow("DEMO · NO LIVE OBSERVATIONS", color: Theme.amber) }
                Text("Learn from your check-ins and review proposed changes.").foregroundStyle(Theme.text2)
                if model.loading { ProgressView("Reading personal comfort…") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber).font(.footnote) }
                if let notice = model.notice { Text(notice).foregroundStyle(Theme.text2).font(.footnote).accessibilityIdentifier("comfort.notice") }
                if let status = model.status {
                    statusCard(status)
                    if let state = status.state {
                        GroupedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ComfortValueRow("Learned offset", value: "\(state.offsetF > 0 ? "+" : "")\(state.offsetF)°F")
                                Text("Proposed changes are limited to 1°F at a time.").font(.footnote).foregroundStyle(Theme.text2)
                                ComfortValueRow("Comfort range", value: "\(state.config.minimumF)–\(state.config.maximumF)°F")
                                Button("Edit Preview settings") { editor = .init(original: state.config, features: status.features) }.accessibilityIdentifier("comfort.configure")
                                if state.config.mode == "preview" || state.config.mode == "active" {
                                    Button(state.config.mode == "active" ? "Stop personal comfort" : "Stop Preview") { Task { _ = await model.stopPreview() } }
                                        .accessibilityIdentifier("comfort.stop")
                                }
                                if state.pausedUntil > status.generatedAt { Text("Manual pause until \(PersonalComfortDates.clock(state.pausedUntil, timezone: status.timezone)).").font(.footnote) }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(model.saving || model.loading || model.requiresReload)
                        if state.config.sensorAware == true { PersonalComfortSignalsCard(signals: status.signals) }
                        if state.config.followBedtime == true { timingCard(status) }
                    }
                    checkIn(status)
                    reports(status)
                    if status.features.ownerActivation == true {
                        NavigationLink {
                            ComfortOwnerScreen(side: side, timezone: status.timezone)
                        } label: {
                            Label("Qualification & activation", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }.background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("comfort.owner.open")
                    }
                    observations(status)
                    Text(status.activation.reason).font(.footnote).foregroundStyle(Theme.text2)
                }
                Button("Refresh personal comfort") { Task { await model.load(userInitiated: true) } }.disabled(model.loading || model.saving)
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Personal comfort").navigationBarTitleDisplayMode(.inline)
            .task(id: scope) {
                editor = nil; feedbackDate = ""; feeling = "comfortable"
                guard phase == .active else { model.invalidate(); return }
                let client: (any PersonalComfortClient)? = APIBackend.current.isDemo
                    ? demoClient
                    : (try? CoreRESTClient.configured()).map { CorePersonalComfortClient(transport: $0) }
                model.configure(client: client, side: side)
                await model.load()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard editor == nil else { continue }
                    await model.load()
                }
            }
            .onDisappear { model.invalidate() }
            .sheet(item: $editor) { session in
                NavigationStack { PersonalComfortEditor(model: model, original: session.original, features: session.features) }.tint(Theme.text1)
            }
            .onChange(of: model.status?.deviceDate, initial: true) { _, value in
                if let value, !PersonalComfortDates.feedbackDates(through: value).contains(feedbackDate) { feedbackDate = value }
            }
    }
    private func statusCard(_ status: PersonalComfortStatus) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(status.modeTitle).font(.title3.bold()).accessibilityIdentifier("comfort.mode")
                Text(status.modeExplanation).font(.footnote).foregroundStyle(Theme.text2)
                Text(status.fault ?? status.decision?.reason ?? "No evaluation recorded yet.")
                if let decision = status.decision, decision.eligible, let proposed = decision.proposedF {
                    ComfortValueRow("Proposed target", value: "\(proposed.formatted())°F")
                }
                if status.evaluatedAt != nil { Text("Last evaluated \(PersonalComfortDates.clock(status.evaluatedAt, timezone: status.timezone))").font(.caption).foregroundStyle(Theme.text2) }
                if status.runtime == "stopped" { Text("The personal comfort service is stopped.").font(.footnote).foregroundStyle(Theme.amber) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func timingCard(_ status: PersonalComfortStatus) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bed-entry timing").font(.headline)
                Text(status.timing?.reason ?? "Waiting for an evaluation.").font(.footnote)
                if let selection = status.timing?.selection {
                    ComfortValueRow("Selected shift", value: "\(selection.shiftMinutes > 0 ? "+" : "")\(selection.shiftMinutes) min")
                    Text("Observed entry \(PersonalComfortDates.clock(selection.entryAt, timezone: status.timezone))").font(.caption)
                }
                if status.timing?.state == "ready" {
                    ComfortValueRow("Scheduled baseline", value: Self.temperature(status.timing?.scheduledBaselineF))
                    ComfortValueRow("Timing Preview baseline", value: Self.temperature(status.timing?.phaseBaselineF))
                }
                Text("Temperature phases may shift up to 30 minutes after ten minutes of observed presence. Power and alarms stay fixed. Bed entry is separate from measured sleep onset.").font(.footnote).foregroundStyle(Theme.text2)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("comfort.bedEntry")
    }
    private func checkIn(_ status: PersonalComfortStatus) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Morning check-in").font(.headline)
                Picker("Sleep date", selection: $feedbackDate) {
                    ForEach(PersonalComfortDates.feedbackDates(through: status.deviceDate ?? ""), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Text(status.timezone ?? "Controller timezone unavailable").font(.caption).foregroundStyle(Theme.text2)
                Picker("How did the bed feel?", selection: $feeling) { Text("Comfortable").tag("comfortable"); Text("Too warm").tag("warm"); Text("Too cold").tag("cold") }.pickerStyle(.menu)
                Button("Save check-in") { Task { _ = await model.saveFeedback(.init(date: feedbackDate, comfort: feeling)) } }
                    .accessibilityIdentifier("comfort.feedback.save")
                    .disabled(model.loading || model.saving || status.fault != nil || status.deviceDate == nil)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func reports(_ status: PersonalComfortStatus) -> some View {
        if status.features.nightReports == true {
            GroupedCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preview night reports").font(.headline)
                    if let error = model.reportsError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                    if let reports = model.reports {
                        ComfortValueRow("Owner-confirmed nights", value: "\(reports.ownerConfirmedNights) / \(reports.targetNights) minimum")
                        Text("Confirmation requires four hours of fresh occupied observation intervals. These are sampled checks, not measured sleep duration. Reviews never activate the bed.").font(.footnote).foregroundStyle(Theme.text2)
                        if reports.items.isEmpty { Text("No overnight Preview report has been recorded.").font(.footnote) }
                        if let client = model.client {
                            ForEach(reports.items) { item in
                                NavigationLink { ComfortNightReportScreen(client: client, side: side, id: item.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.summary.localDate).font(.headline)
                                        Text("\(item.label) · \(item.summary.observationCount) checks").font(.footnote).foregroundStyle(Theme.text2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                }.accessibilityIdentifier("comfort.report.\(item.id)")
                            }
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func observations(_ status: PersonalComfortStatus) -> some View {
        GroupedCard {
            DisclosureGroup("Recent observations") {
                VStack(alignment: .leading, spacing: 12) {
                    if status.history.isEmpty { Text("No observations recorded.") }
                    ForEach(Array(status.history.prefix(10).enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(PersonalComfortDates.clock(entry.at, timezone: status.timezone)).font(.caption).foregroundStyle(Theme.text2)
                            Text(entry.message).font(.footnote)
                            if let timing = entry.timing { Text(timing.reason).font(.caption) }
                            Text("Proposed \(Self.temperature(entry.proposedF)) · reported \(Self.temperature(entry.reportedF)) · owner \(entry.owner ?? "unavailable")").font(.caption).foregroundStyle(Theme.text2)
                        }
                    }
                }.padding(.top, 10)
            }.padding(16)
        }
    }
    static func temperature(_ value: Double?) -> String { value.map { "\($0.formatted())°F" } ?? "Unavailable" }
}

struct ComfortValueRow: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var typeSize
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(title).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value).monospacedDigit().multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}
