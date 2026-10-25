import SwiftUI

struct EpisodeBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @AppStorage("podURL") private var address = ""
    let episodes: [SleepAnalytics.Night]
    let timeZone: String
    @State private var expanded = false
    @State private var selectedID: Int?
    @State private var detail: EpisodeDetail?
    @State private var error: String?
    @State private var loading = false
    @State private var edit: SleepRecordEdit?
    private var ordered: [SleepAnalytics.Night] { episodes.sorted { $0.endedAt > $1.endedAt } }
    private var selected: SleepAnalytics.Night? { ordered.first { $0.id == selectedID } ?? ordered.first }
    private var scope: String { "\(address)|\(model.side.rawValue)|\(selected?.id ?? 0)|\(expanded)|\(model.recordRevision)" }
    var body: some View {
        SleepCard(title: "Your recorded episodes", eyebrow: "NIGHT BY NIGHT", actionTitle: expanded ? "Hide details" : "Browse episodes", action: { expanded.toggle() }) {
            Text("Includes shorter episodes. Times in \(timeZone).").foregroundStyle(SleepTheme.secondary)
            if let message = model.recordMessage { Text(message).sleepText(.caption).foregroundStyle(SleepTheme.success) }
            if expanded {
                if let selected {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recorded episode").sleepText(.small).foregroundStyle(SleepTheme.secondary)
                        Picker("Recorded episode", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                            ForEach(ordered) { episode in Text(label(episode)).tag(episode.id) }
                        }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SleepTheme.border(scheme)))
                            .accessibilityLabel("Recorded episode")
                    }
                    if loading { ProgressView("Loading episode…") }
                    if let error {
                        Text(error).foregroundStyle(SleepTheme.error)
                        Button("Retry") { Task { await load() } }.buttonStyle(SleepButtonStyle())
                    }
                    if let detail, !loading, error == nil {
                        HStack {
                            Button("Edit record") { openEditor(detail, action: .edit) }.buttonStyle(SleepButtonStyle())
                            Button("Delete record", role: .destructive) { openEditor(detail, action: .delete) }.buttonStyle(SleepButtonStyle(kind: .text))
                        }
                        EpisodeDetailContent(detail: detail).id("\(model.side.rawValue):\(selected.id)")
                    }
                } else { Text("No episodes in this range.") }
            }
        }.task(id: scope) { await load() }
            .sheet(item: $edit) { SleepRecordEditor(edit: $0) }
    }
    private func openEditor(_ detail: EpisodeDetail, action: SleepRecordEdit.Action) {
        edit = .init(episode: detail.episode, side: model.side, timeZone: timeZone, action: action,
                     address: address, connectionRevision: model.connectionRevision)
    }
    private func label(_ episode: SleepAnalytics.Night) -> String {
        guard let start = EpisodeDetail.date(episode.startedAt), let end = EpisodeDetail.date(episode.endedAt) else { return episode.date }
        return EpisodeDetail.clock(end, timeZone: timeZone, format: "MMM d, yyyy") + " · "
            + EpisodeDetail.clock(start, timeZone: timeZone, format: "HH:mm") + "–" + EpisodeDetail.clock(end, timeZone: timeZone, format: "HH:mm")
    }
    private func load() async {
        detail = nil; error = nil
        guard expanded, let selected else { loading = false; return }
        let requestedScope = scope; let side = model.side.rawValue
        loading = true
        do {
            let result: EpisodeDetail
            if model.demo {
                result = try model.demoHistory.detail(id: selected.id, side: model.side)
            } else {
                result = try await PodClient.configured().get("analytics/episodes/\(selected.id)", query: [URLQueryItem(name: "side", value: side)])
            }
            guard !Task.isCancelled, requestedScope == scope else { return }
            guard result.side == side, result.episode.id == selected.id else { throw PodError.message("The returned episode does not match this side. Retry the request.") }
            detail = result; loading = false
        } catch {
            guard !Task.isCancelled, requestedScope == scope else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
}
