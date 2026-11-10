import SwiftUI
import FreeSleepKit

struct TonightOverview: View {
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @Environment(AlarmWorkspace.self) private var alarms
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("household.boundaryRevision") private var boundary = ""
    @State private var workspace = TonightWorkspace()
    private var side: Side { TonightSummary.planSide(selected: device.selectedSide.primarySide, settings: settings.settings) }
    private var scope: String { "\(owner)|\(backend)|\(endpoint)|\(host)|\(boundary)|\(side)|\(phase)|\(settings.timeZone)" }

    var body: some View {
        if !PersonalWorkspaceBoundary.isActive {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 16) {
                    if TonightSummary.isMorning(now: context.date, timeZone: settings.timeZone) { MorningReportPreview() }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text("\(settings.sideName(for: side)) · tonight’s plan").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Refresh tonight’s plan", systemImage: "arrow.clockwise") { Task { await workspace.refresh() } }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).buttonStyle(.plain)
                                .disabled(workspace.busy).accessibilityIdentifier("tonight.refresh")
                        }
                        if APIBackend.current.isDemo { Text("Example only · no Pod connected").font(.caption).foregroundStyle(Theme.amber) }
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        layout {
                            comfort(now: context.date).frame(maxWidth: .infinity, alignment: .leading)
                            wake(now: context.date).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        DisclosureGroup("About this saved plan") {
                            Text("Acknowledgments do not verify physical warming or vibration. Manual holds can temporarily override the automatic range.")
                                .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }.font(.footnote)
                    }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                }.frame(maxWidth: 780).frame(maxWidth: .infinity)
            }
            .task(id: scope) {
                workspace.invalidate()
                guard phase == .active, !PersonalWorkspaceBoundary.isActive else { return }
                if APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() {
                    workspace.configure(side: side,
                        comfort: { try await CorePersonalComfortClient(transport: transport).status(side: $0) },
                        alarm: { try await CoreNextAlarmClient(transport: transport).read(side: $0) },
                        limit: { try await CoreComfortLimitClient(transport: transport).read(side: $0) })
                } else if APIBackend.current.isDemo {
                    let alarm = alarms.occurrenceClient(timeZone: settings.timeZone)
                    let limit = DemoComfortLimitClient()
                    workspace.configure(side: side, comfort: nil, alarm: { target in
                        guard let alarm else { throw APIError.noBaseURL }; return try await alarm.read(side: target)
                    }, limit: { await limit.read(side: $0) })
                }
                repeat {
                    await workspace.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                } while !Task.isCancelled
            }
            .onDisappear { workspace.invalidate() }
        }
    }
    private func comfort(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal Autopilot").font(.subheadline).foregroundStyle(Theme.text2)
            Text(TonightSummary.mode(workspace.comfort(at: now), now: now)).font(.subheadline.bold()).accessibilityIdentifier("tonight.mode")
            if let limit = workspace.limit(at: now) {
                Text(limit.config.enabled ? "\(limit.config.minF)–\(limit.config.maxF)°F automatic range" : "No automatic range enabled").font(.footnote).foregroundStyle(Theme.text2)
            } else { Text("Automatic range not checked").font(.footnote).foregroundStyle(Theme.text2) }
            NavigationLink("Review Autopilot") { PersonalComfortDestination(side: side) }.font(.subheadline).frame(minHeight: 44)
                .accessibilityIdentifier("tonight.autopilot")
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func wake(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next wake-up").font(.subheadline).foregroundStyle(Theme.text2)
            Text(TonightSummary.nextWake(workspace.alarm(at: now), now: now)).font(.subheadline.bold())
            Text(TonightSummary.warming(alarm: workspace.alarm(at: now), limit: workspace.limit(at: now), now: now)).font(.footnote).foregroundStyle(Theme.text2)
            NavigationLink("Review wake plan") { NativeNextAlarmScreen(side: side) }.font(.subheadline).frame(minHeight: 44)
                .accessibilityIdentifier("tonight.alarm")
        }.fixedSize(horizontal: false, vertical: true)
    }
}
