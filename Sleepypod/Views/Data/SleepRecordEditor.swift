import SwiftUI

struct SleepRecordEditor: View {
    @Environment(MetricsManager.self) private var metrics
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SleepRecordDraft
    @State private var confirmDelete = false
    let onComplete: () async -> Void
    init(record: SleepRecord, onComplete: @escaping () async -> Void) { _draft = State(initialValue: SleepRecordDraft(record)); self.onComplete = onComplete }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(settings.sideName(for: Side(rawValue: draft.original.side) ?? .left)).font(.headline)
                    dateField("Bedtime", date: $draft.bedtime)
                    if draft.original.isOngoing { Toggle("Add wake time", isOn: $draft.hasWake).tint(Theme.green) }
                    if draft.hasWake { dateField("Wake time", date: $draft.wake) }
                    Text(settings.timeZone).font(.footnote).foregroundStyle(Theme.text2)
                    if let validation = draft.validation { Text(validation).font(.footnote).foregroundStyle(Theme.amber) }
                    if let error = metrics.mutationError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                    Button("Delete sleep record", systemImage: "trash", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
                    Text("This changes the record on your Pod. Existing entries in Apple Health are managed separately.").font(.footnote).foregroundStyle(Theme.text2)
                }.frame(maxWidth: 600).padding(20).frame(maxWidth: .infinity)
            }.background(Theme.background).navigationTitle("Edit sleep record").navigationBarTitleDisplayMode(.inline)
            .environment(\.timeZone, SleepCalendar.calendar(timeZone: settings.timeZone).timeZone)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(metrics.isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(draft.validation != nil || metrics.isSaving) }
            }.interactiveDismissDisabled(metrics.isSaving)
            .confirmationDialog("Delete this sleep record?", isPresented: $confirmDelete) {
                Button("Delete record", role: .destructive) { save(deleting: true) }
            } message: { Text("This removes this record from Sleep. It cannot be undone. Sensor readings and Apple Health entries are kept.") }
        }
    }
    private func dateField(_ title: String, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(Theme.text2)
            DatePicker(title, selection: date, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
        }.cardStyle()
    }
    private func save(deleting: Bool = false) {
        Task { if await metrics.change(draft, deleting: deleting) { await onComplete(); dismiss() } }
    }
}
