import SwiftUI
import FreeSleepKit

struct NightExplanationScreen: View {
    let side: Side
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var phase
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("household.boundaryRevision") private var boundary = ""
    @State private var workspace = NightExplanationWorkspace()
    @State private var morning = Date.now
    @State private var reload = 0
    private var timeZone: TimeZone { TimeZone(identifier: settings.timeZone) ?? .gmt }
    private var wakeDate: String { NightExplanation.dateKey(morning, timeZone: timeZone) }
    private var scope: String { "\(owner)|\(backend)|\(endpoint)|\(host)|\(boundary)|\(side)|\(phase)|\(settings.timeZone)|\(wakeDate)|\(reload)" }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(alignment: .leading, spacing: 22) {
                    Text("\(side == .left ? "Left" : "Right") physical zone. Follow requests, reported temperatures and reasons changes were held back. A zone does not identify a sleeper.")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    if APIBackend.current.isDemo { Text("Practice · simulated night history").font(.footnote).foregroundStyle(Theme.amber) }
                    DatePicker("Morning of", selection: $morning, displayedComponents: .date)
                        .environment(\.timeZone, timeZone).accessibilityIdentifier("night.date")
                    Button("Refresh night", systemImage: "arrow.clockwise") { reload += 1 }
                        .frame(minHeight: 44).disabled(workspace.loading).accessibilityIdentifier("night.refresh")
                    if workspace.loading {
                        HStack(alignment: .top) {
                            ProgressView().accessibilityHidden(true)
                            Text("Reading the selected night…").font(.subheadline)
                        }.accessibilityIdentifier("night.loading")
                    }
                    if !PersonalWorkspaceBoundary.isActive, let report = workspace.report(at: context.date) {
                        NightExplanationContent(report: report)
                    } else if !workspace.loading {
                        Text(workspace.error ?? "Night evidence is unavailable or out of date. Refresh after connecting to the Pod. A started night within the last 30 days is required.")
                            .font(.subheadline).accessibilityIdentifier("night.unavailable")
                    }
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: 780, alignment: .leading)
                    .padding(20).frame(maxWidth: .infinity)
            }
        }.background(Theme.background).navigationTitle("What happened overnight?").navigationBarTitleDisplayMode(.inline)
            .task(id: scope) {
                workspace.invalidate()
                guard phase == .active, !PersonalWorkspaceBoundary.isActive else { return }
                let client: (any NightExplanationClient)?
                if APIBackend.current.isDemo { client = DemoNightExplanationClient() }
                else if APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() {
                    client = CoreNightExplanationClient(transport: transport)
                } else { client = nil }
                workspace.configure(client: client, side: side, wakeDate: wakeDate)
                await workspace.refresh()
            }
            .onDisappear { workspace.invalidate() }
    }
}

private struct NightExplanationContent: View {
    let report: NightExplanation
    @Environment(SettingsManager.self) private var settings
    @State private var filter = "all"
    @State private var visibleEvents = 30
    @State private var visibleRoom = 12
    private var events: [NightExplanation.Event] { report.events.filter { filter == "all" || $0.source.rawValue == filter } }
    private var filterTitle: String { NightExplanation.SourceKey(rawValue: filter)?.title ?? "All recorded events" }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("\(clock(report.start)) – \(clock(report.end)) · \(report.timeZone). Read \(clock(report.generatedAt)). Missing records are unknown, not proof that nothing happened.")
                .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("night.window")
            NightTemperatureChart(report: report)
            Menu {
                Picker("Show events", selection: $filter) {
                    Text("All recorded events").tag("all")
                    ForEach([NightExplanation.SourceKey.applications, .decisions, .rules], id: \.self) { source in
                        Text(source.title).tag(source.rawValue)
                    }
                }
            } label: {
                // The default menu picker clips wrapped labels at accessibility text sizes.
                HStack(spacing: 12) {
                    Text(filterTitle).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Show events").accessibilityValue(filterTitle)
                .accessibilityIdentifier("night.filter")
            if report.eventsTruncated { Text("Showing the most recent 600 retained events. Earlier events are not included.").font(.footnote) }
            if events.isEmpty {
                Text("No retained events for this selection. Review source availability below; this does not establish that the bed stayed unchanged.")
                    .font(.subheadline).foregroundStyle(Theme.text2)
            }
            ForEach(events.prefix(visibleEvents)) { event in eventRow(event) }
            if events.count > visibleEvents { Button("Show 30 more events") { visibleEvents += 30 }.frame(minHeight: 44) }
            DisclosureGroup("Room conditions · \(report.room.count) retained reports") {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Latest report per sensor and five-minute bin. The clock label identifies a measurement, device read, integration report or cached value. These reports alone do not explain what caused a temperature change.").font(.footnote).foregroundStyle(Theme.text2)
                    if report.roomTruncated { Text("Only the most recent 2,000 sampled room reports are included.").font(.footnote) }
                    if report.room.isEmpty { Text("No room reports were retained for this window.").font(.footnote) }
                    ForEach(report.room.suffix(visibleRoom).reversed()) { sample in roomRow(sample) }
                    if report.room.count > visibleRoom { Button("Show older room reports") { visibleRoom += 24 }.frame(minHeight: 44) }
                }.padding(.top, 12)
            }.accessibilityIdentifier("night.room")
            DisclosureGroup("Data sources and gaps") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(report.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(source.key.title) · \(sourceStatus(source.status))").font(.subheadline.bold())
                            Text(source.note).font(.footnote).foregroundStyle(Theme.text2)
                            Text("\(source.rowsRead) rows read; \(source.discarded) invalid rows excluded.\(source.truncated ? " Older rows omitted at the read limit." : "")").font(.caption).foregroundStyle(Theme.text2)
                        }
                    }
                    Text("House actions are not yet connected to this timeline. A room sensor or accessory report cannot establish who issued a command. No controls run when you open this view.").font(.footnote).foregroundStyle(Theme.text2)
                }.padding(.top, 12)
            }.accessibilityIdentifier("night.sources")
        }.onChange(of: filter) { visibleEvents = 30 }
    }
    private func eventRow(_ event: NightExplanation.Event) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { Text(clock(event.at)); Text(event.kind.title) }
                VStack(alignment: .leading) { Text(clock(event.at)); Text(event.kind.title) }
            }.font(.footnote).foregroundStyle(Theme.text2)
            Text(event.title + (event.targetF.map { " · \(temperature($0))" } ?? "")).font(.headline)
            Text(event.detail).font(.subheadline)
            if event.count > 1 {
                Text("\(event.count) matching recorded evaluations, through \(clock(event.through)). This count is not continuous sensor coverage.").font(.footnote).foregroundStyle(Theme.text2)
            }
            if event.scope == "unassigned" { Text("No historical side assignment was recorded for this rule evaluation.").font(.footnote).foregroundStyle(Theme.text2) }
            DisclosureGroup("Source detail") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(event.source.title) · \(event.id). Evidence: \(event.evidence.replacingOccurrences(of: "_", with: " ")).")
                    if let value = event.reportedF { Text("Policy’s recorded temperature: \(temperature(value)). This is the policy snapshot, not a separate sensor sample.") }
                }.font(.caption).foregroundStyle(Theme.text2).padding(.top, 8)
            }.font(.footnote)
            Divider().padding(.top, 10)
        }.accessibilityElement(children: .contain)
    }
    private func roomRow(_ sample: NightExplanation.Room) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(sample.label): \(roomValue(sample))").font(.subheadline.bold())
            Text("\(clock(sample.observedAt)) · \(sample.timeBasis.replacingOccurrences(of: "_", with: " "))\(sample.measuredAt.map { " · measured \(clock($0))" } ?? " · measurement time not supplied")")
                .font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func roomValue(_ sample: NightExplanation.Room) -> String {
        guard let value = sample.value else { return "Unavailable" }
        return sample.metric == "temperature" ? temperature(value) : "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(sample.unit)"
    }
    private func temperature(_ value: Double) -> String { TemperatureConversion.displayTemp(Int(value.rounded()), format: settings.temperatureFormat) }
    private func clock(_ value: Double) -> String { AutomationDates.label(value, timeZone: report.timeZone, includeDate: true) }
    private func sourceStatus(_ status: String) -> String {
        switch status {
        case "read": "Read successfully"
        case "empty": "No retained rows"
        case "partial": "Partial evidence"
        default: "Unavailable"
        }
    }
}
