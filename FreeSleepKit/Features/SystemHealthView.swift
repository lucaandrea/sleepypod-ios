import SwiftUI

struct SystemHealthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var rows: [String: ServiceHealth] = [:]
    @State private var received: Date?
    @State private var failure: String?
    @State private var busy = false
    @State private var requestID = UUID()
    var body: some View {
        SleepPage(title: "System health", subtitle: "Status reported by your Pod. Updates every five seconds while this page is open.", narrow: true) {
            if let failure {
                Text(failure + (received == nil ? "" : " The last successful snapshot is shown below.")).foregroundStyle(SleepTheme.error)
            }
            if let received { Text("Last received: \(received.formatted(date: .omitted, time: .standard))").sleepText(.caption).foregroundStyle(SleepTheme.secondary) }
            Button(busy ? "Refreshing…" : "Refresh status") { Task { await load() } }.buttonStyle(SleepButtonStyle()).disabled(busy)
            if received != nil && rows.isEmpty { Text("No service status was returned.") }
            ForEach(rows.keys.sorted { rows[$0]!.name < rows[$1]!.name }, id: \.self) { key in
                if let status = rows[key] {
                    SleepCard(title: status.name) {
                        SleepBadge(title: status.label, tone: tone(status.status))
                        Text(status.description).foregroundStyle(SleepTheme.secondary)
                        if !status.message.isEmpty { Text(status.message).textSelection(.enabled) }
                        if let stamp = status.timestamp.flatMap(EpisodeDetail.date) {
                            Text("Reported: \(stamp.formatted(date: .numeric, time: .standard))").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                        }
                    }
                }
            }
        }.navigationBarTitleDisplayMode(.inline)
            .task(id: "\(model.connectionRevision)|\(phase)") {
                requestID = UUID(); busy = false; rows = [:]; received = nil; failure = nil
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await load()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
    private func tone(_ status: String) -> SleepBadge.Tone {
        switch status {
        case "healthy": .success
        case "failed": .error
        case "retrying", "restarting": .warning
        case "started": .info
        default: .neutral
        }
    }
    private func load() async {
        guard !busy else { return }
        let ticket = requestID
        busy = true
        defer { if ticket == requestID { busy = false } }
        do {
            let result: [String: ServiceHealth]
            if model.demo { result = DeviceDemo.shared?.health ?? [:] }
            else { result = try await PodClient.configured().get("serverStatus") }
            guard !Task.isCancelled, ticket == requestID else { return }
            rows = result; received = .now; failure = nil
        } catch { if !Task.isCancelled && ticket == requestID { failure = error.localizedDescription } }
    }
}
