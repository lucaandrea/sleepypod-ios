import SwiftUI

struct AlarmCard: View {
    @Environment(AppModel.self) private var model
    let side: BedSide
    @State private var preview: AlarmPreview?
    @State private var message: String?
    @State private var edit: AlarmEdit?

    var body: some View {
        SleepCard(title: message == nil ? preview?.title ?? "Loading alarm…" : "Alarm unavailable", eyebrow: "NEXT ALARM", badge: message == nil ? preview?.badge : nil) {
            if let message {
                Text(message).sleepText(.body).foregroundStyle(SleepTheme.error)
                Button("Retry") { Task { await load() } }.buttonStyle(SleepButtonStyle(kind: .outlined))
            } else if let preview {
                Text(preview.detail).sleepText(.body).foregroundStyle(SleepTheme.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { occurrenceActions(preview); restoreAction(preview) }
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { occurrenceActions(preview) }
                            VStack(alignment: .leading, spacing: 8) { occurrenceActions(preview) }
                        }
                        restoreAction(preview)
                    }
                }
                if preview.alarm != nil { Text("Vibration requires this side to be on.").sleepText(.caption).foregroundStyle(SleepTheme.secondary) }
            }
        }
        .sheet(item: $edit, onDismiss: { Task { await load() } }) { item in AlarmEditor(edit: item) }
        .task {
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
    @ViewBuilder private func occurrenceActions(_ preview: AlarmPreview) -> some View {
        if preview.alarm != nil {
            Button("Change time") { edit = .init(preview: preview, action: .time) }.buttonStyle(SleepButtonStyle(kind: .outlined))
            Button("Skip once") { edit = .init(preview: preview, action: .disable) }.buttonStyle(SleepButtonStyle(kind: .outlined))
        }
    }
    @ViewBuilder private func restoreAction(_ preview: AlarmPreview) -> some View {
        if preview.expiresAt != nil {
            Button("Use routine") { edit = .init(preview: preview, action: .restore) }.buttonStyle(SleepButtonStyle(kind: .outlined))
        }
    }
    private func load() async {
        do {
            let result: AlarmPreview
            if model.demo { result = model.demoAlarms.preview(side: side) }
            else { result = try await PodClient.configured().get("alarm/next", query: [URLQueryItem(name: "side", value: side.rawValue)]) }
            guard !Task.isCancelled else { return }
            preview = result; message = nil
        } catch { if !Task.isCancelled { message = "Check your Pod connection and server version." } }
    }
}
