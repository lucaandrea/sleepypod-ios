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
        FeaturePage(title: "Pod services") {
            if let failure {
                Text(failure + (received == nil ? "" : " The last successful snapshot is shown below.")).foregroundStyle(Theme.red)
            }
            if let received { Text("Last received: \(received.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.text2) }
            Button(busy ? "Refreshing…" : "Refresh status") { Task { await load() } }.buttonStyle(GlassButtonStyle()).disabled(busy)
            if received != nil && rows.isEmpty { Text("No service status was returned.") }
            ForEach(rows.keys.sorted { rows[$0]!.name < rows[$1]!.name }, id: \.self) { key in
                if let status = rows[key] {
                    FeatureSection(title: status.name) {
                        FeatureStatus(title: status.label, tone: tone(status.status))
                        Text(status.description).foregroundStyle(Theme.text2)
                        if !status.message.isEmpty { Text(status.message).textSelection(.enabled) }
                        if let stamp = status.timestamp.flatMap(EpisodeDetail.date) {
                            Text("Reported: \(stamp.formatted(date: .numeric, time: .standard))").font(.caption).foregroundStyle(Theme.text2)
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
    private func tone(_ status: String) -> FeatureStatus.Tone {
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
