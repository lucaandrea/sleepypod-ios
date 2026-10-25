import SwiftUI

struct AlarmEdit: Identifiable {
    let id = UUID()
    var preview: AlarmPreview
    var action: AlarmChange.Action
    var title: String { action == .time ? "Change this alarm" : action == .disable ? "Skip this alarm?" : "Use your routine?" }
    var button: String { action == .time ? "Save time" : action == .disable ? "Skip once" : "Use routine" }
    var explanation: String {
        action == .time ? "Only this alarm changes. Choose a future time on the displayed date."
        : action == .disable ? "Skip this occurrence. Your saved routine stays the same."
        : "Remove the one-time change and return to your saved routine."
    }
}

struct AlarmEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let edit: AlarmEdit
    @State private var clock: Date
    @State private var saving = false
    @State private var message: String?

    init(edit: AlarmEdit) {
        self.edit = edit
        _clock = State(initialValue: AlarmClock.date(edit.preview.alarm?.time ?? "07:00"))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(edit.preview.side == .left ? "Left side" : "Right side") · \(edit.preview.timeZone)").sleepText(.body).foregroundStyle(SleepTheme.secondary)
                    if let alarm = edit.preview.alarm { Text(edit.preview.format(alarm.at, pattern: "EEE, MMM d · h:mm a")).sleepText(.cardTitle) }
                    Text(edit.explanation).sleepText(.body)
                    if edit.action == .time {
                        DatePicker("Alarm time", selection: $clock, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, .gmt).disabled(saving)
                    }
                    if let message { Text(message).sleepText(.body).foregroundStyle(SleepTheme.error) }
                    Button(saving ? "Saving…" : edit.button) { Task { await save() } }
                        .buttonStyle(SleepButtonStyle(kind: .primary))
                        .disabled(saving || (edit.action == .time && AlarmClock.time(clock) == edit.preview.alarm?.time))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .background(SleepTheme.canvas(scheme)).navigationTitle(edit.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
        }.interactiveDismissDisabled(saving).presentationDetents([.medium, .large])
    }
    private func save() async {
        saving = true; message = nil
        defer { saving = false }
        let request = AlarmChange(preview: edit.preview, action: edit.action, time: AlarmClock.time(clock))
        do {
            if model.demo { _ = try model.demoAlarms.change(request) }
            else { let _: AlarmPreview = try await PodClient.configured().postReturning("alarm/override", body: request) }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
