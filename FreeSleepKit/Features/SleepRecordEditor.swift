import SwiftUI

struct SleepRecordEdit: Identifiable {
    enum Action { case edit, delete }
    let id = UUID()
    var episode: SleepAnalytics.Night
    var side: BedSide
    var timeZone: String
    var action: Action
    var address: String
    var connectionRevision: Int
}

struct SleepRecordEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let edit: SleepRecordEdit
    @State private var start: Date
    @State private var end: Date
    @State private var saving = false
    @State private var error: String?
    private var identity: SleepRecordIdentity { .init(side: edit.side, episode: edit.episode) }
    private var valid: Bool { SleepRecordChange.valid(start: start, end: end) }
    private var unchanged: Bool {
        floor(start.timeIntervalSince1970) == EpisodeDetail.date(edit.episode.startedAt).map { floor($0.timeIntervalSince1970) }
            && floor(end.timeIntervalSince1970) == EpisodeDetail.date(edit.episode.endedAt).map { floor($0.timeIntervalSince1970) }
    }
    init(edit: SleepRecordEdit) {
        self.edit = edit
        _start = State(initialValue: EpisodeDetail.date(edit.episode.startedAt) ?? .distantPast)
        _end = State(initialValue: EpisodeDetail.date(edit.episode.endedAt) ?? .distantPast)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(edit.side.title) · \(edit.timeZone)").foregroundStyle(SleepTheme.secondary)
                    Text(edit.action == .edit ? "Correct the episode window. Original sensor intervals and vital readings stay unchanged."
                        : "This removes the episode from Free Sleep history and analytics. Original vital readings remain. This cannot be undone.")
                    if edit.action == .edit {
                        DatePicker("Entered bed", selection: $start, displayedComponents: [.date, .hourAndMinute]).disabled(saving)
                            .accessibilityIdentifier("record-start")
                        Text(clock(start)).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                        DatePicker("Left bed", selection: $end, displayedComponents: [.date, .hourAndMinute]).disabled(saving)
                            .accessibilityIdentifier("record-end")
                        Text(clock(end)).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                        if !valid { Text("Choose an end after the start, within a 72-hour window.").foregroundStyle(SleepTheme.error) }
                    } else { Text("\(clock(start)) — \(clock(end))") }
                    Text("Health sync reconciles previous Apple Health exports within its sync window.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    if let error { Text(error).foregroundStyle(SleepTheme.error).accessibilityIdentifier("record-error") }
                    Button(saving ? "Saving…" : edit.action == .edit ? "Save changes" : "Delete record",
                           role: edit.action == .delete ? .destructive : nil) { Task { await save() } }
                        .buttonStyle(SleepButtonStyle(kind: edit.action == .delete ? .outlined : .primary, fill: true))
                        .disabled(saving || (edit.action == .edit && (!valid || unchanged)))
                }.sleepText(.body).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.background(SleepTheme.canvas(scheme))
                .environment(\.timeZone, TimeZone(identifier: edit.timeZone) ?? .gmt)
                .navigationTitle(edit.action == .edit ? "Edit record" : "Delete this record?").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
        }.interactiveDismissDisabled(saving).presentationDetents([.large])
    }
    private func clock(_ date: Date) -> String { EpisodeDetail.clock(date, timeZone: edit.timeZone, format: "MMM d, yyyy HH:mm z (ZZZZZ)") }
    private func save() async {
        guard !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            guard model.connectionRevision == edit.connectionRevision else { throw PodError.message("Your connection changed. Close this editor and reopen the record.") }
            if model.demo {
                if edit.action == .delete { try model.demoHistory.delete(id: edit.episode.id, identity: identity) }
                else { try model.demoHistory.change(id: edit.episode.id, change: SleepRecordChange(identity: identity, start: start, end: end)) }
            } else {
                let client = try PodClient.configured()
                guard client.baseURL == (try ConnectionEndpoint.url(edit.address)) else { throw PodError.message("Your connection changed. Close this editor and reopen the record.") }
                if edit.action == .delete { try await client.deleteRecord(edit.episode.id, identity: identity) }
                else { try await client.editRecord(edit.episode.id, change: SleepRecordChange(identity: identity, start: start, end: end)) }
            }
            if model.connectionRevision == edit.connectionRevision {
                model.recordsChanged(message: edit.action == .delete ? "Record deleted." : "Record updated.")
                await model.refresh()
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
