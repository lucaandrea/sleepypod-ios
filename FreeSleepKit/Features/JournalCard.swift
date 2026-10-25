import SwiftUI

struct JournalCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("podURL") private var address = ""
    @State private var selectedDate: String?
    @State private var journal: Journal?
    @State private var loadedScope: String?
    @State private var loadError: String?
    @State private var status: (key: String, text: String, failed: Bool)?
    private var workspace: JournalWorkspace { model.journalWorkspace }
    private var timeZone: String { model.settings?.timeZone ?? model.analytics?.timeZone ?? "UTC" }
    private var dateKey: String { selectedDate ?? JournalDate.key(Date(), timeZone: timeZone) }
    private var pod: String { model.demo ? "demo" : address + "|" + (model.settings?.id ?? "") }
    private var key: String { "\(pod)|\(model.side.rawValue)|\(dateKey)" }
    private var scope: String { "\(key)|\(model.days)" }
    private var value: JournalEntry { workspace.drafts[key] ?? journal?.selected ?? JournalEntry(date: dateKey, side: model.side.rawValue) }
    private var binding: Binding<JournalEntry> {
        Binding(get: { value }, set: { workspace.put(key, value: $0); status = nil })
    }
    var body: some View {
        SleepCard(title: "How did the night feel?", eyebrow: "YOUR MORNING CHECK-IN") {
            SleepFormField(title: "Wake date") {
                DatePicker("Wake date", selection: Binding(get: {
                    JournalDate.date(dateKey, timeZone: timeZone) ?? Date()
                }, set: { selectedDate = JournalDate.key($0, timeZone: timeZone) }), displayedComponents: .date)
                    .labelsHidden().environment(\.timeZone, TimeZone(identifier: timeZone) ?? .gmt)
                    .environment(\.calendar, Calendar(identifier: .gregorian)).accessibilityLabel("Wake date")
            }
            Text("Wake date in \(timeZone) · \(model.side.rawValue) side").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            if let loadError {
                Text(loadError).sleepText(.small).foregroundStyle(SleepTheme.error)
                Button("Retry") { Task { await load() } }.buttonStyle(SleepButtonStyle())
            } else if loadedScope == scope, journal?.selectedDate == dateKey { form }
            else { ProgressView("Loading check-in…") }
            Text("Saved notes stay on your Pod. Coaching receives numerical patterns and your submitted question only when you allow sharing.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            if loadedScope == scope, let patterns = journal?.patterns {
                ForEach(patterns.associations, id: \.habit) { pattern in
                    Text("\(pattern.habit): \(pattern.presenceDifferenceMinutes > 0 ? "+" : "")\(pattern.presenceDifferenceMinutes) minutes of bed presence on recorded nights with this habit (\(pattern.withCount) with / \(pattern.withoutCount) without).")
                        .sleepText(.body)
                }
                Text(patterns.note).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
        }.task(id: "\(scope)|\(workspace.revision)") { await load() }
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            SleepFormField(title: "Restfulness") {
                Picker("Restfulness", selection: binding.restfulness) {
                    Text("Very low").tag(1); Text("Low").tag(2); Text("Okay").tag(3); Text("Good").tag(4); Text("Great").tag(5)
                }.pickerStyle(.menu).labelsHidden().tint(SleepTheme.text).accessibilityLabel("Restfulness")
            }
            SleepFormField(title: "Temperature comfort") {
                Picker("Temperature comfort", selection: binding.comfort) {
                    Text("Too cold").tag("cold"); Text("Comfortable").tag("comfortable"); Text("Too warm").tag("warm")
                }.pickerStyle(.menu).labelsHidden().tint(SleepTheme.text).accessibilityLabel("Temperature comfort")
            }
            VStack(spacing: 0) {
                Toggle("Caffeine", isOn: binding.caffeine); Toggle("Alcohol", isOn: binding.alcohol); Toggle("Exercise", isOn: binding.exercise)
            }.toggleStyle(SleepCheckboxStyle())
            SleepNotesField(title: "Notes for yourself", limit: 500, text: binding.notes)
            Button(workspace.saving.contains(key) ? "Saving…" : "Save check-in") { Task { await save() } }
                .buttonStyle(SleepButtonStyle(kind: .primary, fill: true))
            Button("Reset draft") { workspace.clear(key); status = nil }
                .buttonStyle(SleepButtonStyle(fill: true)).disabled(workspace.drafts[key] == nil)
            if let status, status.key == key {
                Text(status.text).sleepText(.caption).foregroundStyle(status.failed ? SleepTheme.error : SleepTheme.success)
            }
            Text("Unsaved notes stay per Pod, side and wake date while this app is open.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }.disabled(workspace.saving.contains(key))
    }
    private func load() async {
        let requested = scope; let requestedKey = key; let date = dateKey; let side = model.side; let days = model.days
        loadedScope = nil; journal = nil; loadError = nil
        do {
            let response: Journal
            if model.demo { response = workspace.demoJournal(key: requestedKey, date: date, side: side.rawValue, days: days,
                                                           nights: model.demoHistory.analytics(side: side, days: days)?.nights) }
            else { response = try await PodClient.configured().get("journal", query: [URLQueryItem(name: "side", value: side.rawValue),
                URLQueryItem(name: "date", value: date), URLQueryItem(name: "days", value: String(days))]) }
            guard !Task.isCancelled, requested == scope else { return }
            guard response.selectedDate == date, response.selected.map({ $0.side == side.rawValue && $0.date == date }) ?? true else {
                throw PodError.message("Update your Free Sleep server to load check-ins by wake date before editing.")
            }
            journal = response; loadedScope = requested
        } catch { if !Task.isCancelled, requested == scope { loadError = error.localizedDescription } }
    }
    private func save() async {
        guard loadedScope == scope, workspace.beginSave(key) else { return }
        let requestedKey = key; let requestedScope = scope; let posted = value
        status = nil; defer { workspace.finishSave(requestedKey) }
        do {
            let saved: JournalEntry
            if model.demo { saved = workspace.saveDemo(requestedKey, value: posted) }
            else { saved = try await PodClient.configured().postReturning("journal", body: posted) }
            workspace.clear(requestedKey, expected: posted)
            if requestedScope == scope { journal?.selected = saved }
            workspace.saved()
            status = (requestedKey, "Check-in saved.", false)
        } catch { status = (requestedKey, error.localizedDescription, true) }
    }
}
