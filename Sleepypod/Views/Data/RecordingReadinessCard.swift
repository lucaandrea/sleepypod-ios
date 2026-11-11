import SwiftUI

struct RecordingReadinessCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RecordingReadinessWorkspace()
    @State private var expanded = false
    @State private var refreshRevision = 0

    var body: some View {
        content
        .task(id: OwnerConnection.revision + [String(describing: scenePhase), String(refreshRevision)]) {
            model.invalidate()
            guard scenePhase == .active else { return }
            let client: (any RecordingReadinessClient)?
            if APIBackend.current.isDemo { client = DemoRecordingReadinessClient() }
            else if APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() {
                client = CoreRecordingReadinessClient(transport: transport)
            } else { client = nil }
            model.configure(client: client)
            repeat {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear { model.invalidate() }
    }

    private var content: some View {
        let report = model.report
        return VStack(alignment: .leading, spacing: 12) {
            // Freshness ticks only update the status region, not the interactive disclosure subtree.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                statusContent(for: report?.status(at: timeline.date) ?? .unavailable)
            }
            if let report {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(expanded ? "Hide recording checks" : "See recording checks")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("recording.readiness.details")
                if expanded {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Checked \(report.checkedDate.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(Theme.text2)
                            .accessibilityIdentifier("recording.readiness.checked")
                        ForEach(report.checks) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.title).font(.subheadline.weight(.semibold))
                                Text(check.statusLabel).font(.caption).foregroundStyle(Theme.text2)
                                Text(check.detail).font(.footnote)
                                if let next = check.nextStep { Text(next).font(.footnote).foregroundStyle(Theme.amber) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.top, 12)
                }
            }
            Button { refreshRevision += 1 } label: {
                Label(model.loading ? "Checking…" : "Check again", systemImage: "arrow.clockwise").frame(minHeight: 44)
            }.disabled(model.loading).accessibilityIdentifier("recording.readiness.refresh")
            NavigationLink("Open recording diagnostics") { SystemHealthScreen() }
                .font(.subheadline).frame(minHeight: 44)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
            .onChange(of: report?.status(at: Date()) ?? .unavailable) { _, next in
                if next == .attention { expanded = true }
            }
    }

    private func statusContent(for status: RecordingReadiness.Status) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if APIBackend.current.isDemo { Text("DEMO · simulated recording checks").font(.caption).foregroundStyle(Theme.amber) }
            Label(title(for: status), systemImage: status == .ready ? "checkmark.circle" : status == .attention ? "exclamationmark.triangle" : "questionmark.circle")
                .font(.headline).foregroundStyle(status == .ready ? Theme.green : status == .attention ? Theme.amber : Theme.text1)
                .accessibilityIdentifier("recording.readiness.title")
            Text("Current Pod checks cover recording equipment, not sleep quality or Watch imports.")
                .font(.footnote).foregroundStyle(Theme.text2)
            if status == .unavailable {
                Text(model.error ?? "Reconnect to check the sensors and storage. A saved result cannot confirm that recording is working now.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
        }
    }
    private func title(for status: RecordingReadiness.Status) -> String {
        switch status {
        case .ready: "Recording checks are ready"
        case .attention: "Recording needs attention"
        case .unknown: "Recording checks are incomplete"
        case .unavailable: model.loading ? "Checking recording readiness…" : "Recording check unavailable"
        }
    }
}
