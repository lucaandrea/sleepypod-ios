import SwiftUI

struct PersonalJournalScreen: View {
    let model: PersonalJournalWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var date = Date()
    @State private var reviewOpen = false
    @State private var openToday = false
    @State private var reviewDelete = false
    @FocusState private var focus: String?
    var body: some View {
        Form {
            Section {
                Text("Remember how the night felt. Your check-in belongs to your personal account, whichever side you slept on.")
                Text("Check-ins describe your experience. Saving one does not change the bed or train a model.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(Theme.text1).accessibilityIdentifier("personalJournal.error") }
            }
            if let notice = model.notice {
                Section { Text(notice).accessibilityIdentifier("personalJournal.notice") }
            }
            if model.pending != nil {
                Section { Button("Check saved result") { Task { await model.reconcile() } }
                    .disabled(model.busy).accessibilityIdentifier("personalJournal.reconcile") }
            }
            if let selected = model.selected, model.draft != nil {
                Section {
                    DatePicker("Wake date", selection: $date, displayedComponents: .date)
                        .environment(\.timeZone, .gmt).disabled(model.busy).accessibilityIdentifier("personalJournal.date")
                    Button("Open date") { requestOpen(today: false) }.disabled(model.busy)
                    Button("Today") { requestOpen(today: true) }.disabled(model.busy)
                    Text(selected.date).font(.headline).accessibilityIdentifier("personalJournal.openDate")
                    Text("\(model.entryStatus) · \(model.timeZone)").font(.footnote).foregroundStyle(Theme.text2)
                        .accessibilityIdentifier("personalJournal.savedState")
                }
                Section("How did you feel?") {
                    Picker("How rested did you feel?", selection: binding(\.restfulness)) {
                        Text("Choose how rested").tag(Int?.none)
                        Text("1 — Very tired").tag(Int?.some(1)); Text("2 — Somewhat tired").tag(Int?.some(2))
                        Text("3 — In between").tag(Int?.some(3)); Text("4 — Rested").tag(Int?.some(4))
                        Text("5 — Very rested").tag(Int?.some(5))
                    }.accessibilityIdentifier("personalJournal.restfulness")
                    Picker("Bed temperature comfort", selection: binding(\.comfort)) {
                        Text("Choose your comfort").tag(String?.none)
                        Text("Too cold").tag(String?.some("cold")); Text("Comfortable").tag(String?.some("comfortable"))
                        Text("Too warm").tag(String?.some("warm"))
                    }.accessibilityIdentifier("personalJournal.comfort")
                    TextField("Anything to remember? Optional", text: binding(\.notes), axis: .vertical)
                        .lineLimit(3...8).focused($focus, equals: "notes").accessibilityIdentifier("personalJournal.notes")
                    Text("\(model.draft?.notes.utf16.count ?? 0) / 500 characters").font(.caption).foregroundStyle(Theme.text2)
                }.disabled(!model.editable)
                Section {
                    DisclosureGroup {
                        MorningJournalContextEditor(draft: binding(\.context), wakeDate: selected.date, timeZone: model.timeZone, focus: $focus)
                            .padding(.vertical, 8)
                    } label: {
                        Text("Add habits and timing (optional)").accessibilityIdentifier("personalJournal.context")
                    }.disabled(!model.editable)
                }
                Section {
                    if let issue = model.validationIssue {
                        Text(issue).font(.footnote).foregroundStyle(Theme.text1).accessibilityIdentifier("personalJournal.validation")
                    }
                    Button("Save my check-in") { focus = nil; Task { await model.save() } }
                        .disabled(!model.canSave).accessibilityIdentifier("personalJournal.save")
                    if selected.record != nil {
                        Button("Remove this check-in…", role: .destructive) { reviewDelete = true }
                            .disabled(!model.editable).accessibilityIdentifier("personalJournal.remove")
                    }
                } footer: {
                    Text("Drafts stay only on this screen. Save before leaving or switching apps; private content is cleared when this screen is hidden.")
                }
            } else if model.enabled {
                Section { Button(model.busy ? "Opening check-in…" : "Open my check-in") { Task { await model.open() } }
                    .disabled(model.busy).accessibilityIdentifier("personalJournal.open") }
            } else {
                Section { Text("Personal check-ins are not enabled on this Pod yet. Return to your account and refresh to check availability.") }
            }
            if model.busy { Section { ProgressView("Checking your personal account…") } }
        }
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Morning check-in").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Leave this draft?", isPresented: $reviewOpen, titleVisibility: .visible) {
            Button("Discard draft and open entry", role: .destructive) { open(discard: true) }
            Button("Keep this draft") { reviewOpen = false }
        } message: {
            Text(model.pending == nil ? "Opening another entry discards these unsaved changes."
                 : "The earlier save may have reached your Pod. Reopening reads the current entry; it never sends that save again.")
        }
        .confirmationDialog("Remove this check-in?", isPresented: $reviewDelete, titleVisibility: .visible) {
            Button("Delete check-in", role: .destructive) { focus = nil; Task { await model.save(remove: true) } }
            Button("Keep check-in") { reviewDelete = false }
        } message: { Text("This removes the current entry from your personal journal. Existing backups and exports are unchanged.") }
        .onChange(of: model.selected?.date) {
            if let selected = model.selected, let value = MorningJournalDates.localDate(selected.date, timeZone: "GMT") { date = value }
        }
        .task {
            if model.page == nil { await model.open() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await model.checkAccess()
            }
        }
        .onChange(of: scenePhase) { if scenePhase != .active { model.suspend(); reviewOpen = false; reviewDelete = false } }
        .onDisappear { model.suspend() }
    }
    private func binding<Value>(_ path: WritableKeyPath<PersonalJournalDraft, Value>) -> Binding<Value> {
        Binding(get: { (model.draft ?? PersonalJournalDraft(fields: nil, timeZone: model.timeZone))[keyPath: path] },
                set: { value in guard var draft = model.draft else { return }; draft[keyPath: path] = value; model.edit(draft) })
    }
    private func requestOpen(today: Bool) {
        openToday = today
        if model.hasUnsaved { reviewOpen = true } else { open(discard: false) }
    }
    private func open(discard: Bool) {
        focus = nil
        let selected = openToday ? nil : MorningJournalDates.key(date, timeZone: "GMT")
        Task { await model.open(date: selected, discardDraft: discard) }
    }
}
