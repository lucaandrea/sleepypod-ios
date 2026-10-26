import SwiftUI
import FreeSleepKit

struct MorningJournalDestination: View {
    let side: Side
    var body: some View {
        if APIBackend.current == .freeSleep { PodFeatureScreen(.journal, side: side.rawValue) }
        else { MorningJournalScreen(side: side) }
    }
}

struct MorningJournalScreen: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @State private var model = MorningJournalWorkspace()
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @FocusState private var notesFocused: Bool
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    let side: Side
    private var scope: String { "\(backend)|\(address)|\(host)|\(ownerRevision)" }
    private var fields: Binding<MorningJournalFields> {
        Binding(get: { model.draft?.fields ?? .init() }, set: { model.edit($0) })
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Color.clear.frame(height: 1).id("journal.top")
                if APIBackend.current.isDemo { Eyebrow("DEMO · CHECK-INS STAY IN THIS PREVIEW", color: Theme.amber) }
                if model.busy { ProgressView("Updating journal…") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("journal.error") }
                if let notice = model.notice { Text(notice).foregroundStyle(Theme.text2).accessibilityIdentifier("journal.notice") }
                if let page = model.page { selection(page) }
                if let draft = model.draft {
                    Text("\(model.side.displayName) · \(draft.original.date)").font(.title3.bold())
                    if let comparison = draft.comparison { comparisonCard(comparison) }
                    editor(draft)
                }
                Button(model.draft?.needsReadback == true ? "Read saved entry" : "Reload journal") { notesFocused = false; Task { await model.load() } }
                    .disabled(model.busy).accessibilityIdentifier("journal.reload")
                if let page = model.page { MorningJournalPatternsCard(patterns: page.patterns); entries(page) }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("journal.scroll").scrollDismissesKeyboard(.interactively).background(Theme.background)
            .onChange(of: model.date) { proxy.scrollTo("journal.top", anchor: .top) }
            .onChange(of: model.error) { if model.error != nil { proxy.scrollTo("journal.top", anchor: .top) } }
            .onChange(of: model.notice) { if model.notice != nil { proxy.scrollTo("journal.top", anchor: .top) } }
        }
            .navigationTitle("Morning check-in").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(model.hasUnsaved)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { notesFocused = false }
                }
                if model.hasUnsaved {
                    ToolbarItem(placement: .topBarLeading) { Button("Back", systemImage: "chevron.left") { confirmLeave = true } }
                }
            }
            .interactiveDismissDisabled(model.hasUnsaved || model.busy)
            .confirmationDialog("Discard unsaved check-in drafts?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Discard drafts and leave", role: .destructive) { dismiss() }
            } message: { Text("Saved entries stay on your controller. An unconfirmed save may already have been applied; read it again when you return.") }
            .confirmationDialog("Delete this saved check-in?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete check-in", role: .destructive) { notesFocused = false; Task { _ = await model.save(delete: true) } }
            } message: { Text("Only the selected side and wake date will be removed.") }
            .task(id: scope) {
                let client: (any MorningJournalClient)? = APIBackend.current.isDemo ? DemoMorningJournalClient(scenario: DebugRoute.journalScenario)
                    : (try? CoreRESTClient.configured()).map { CoreMorningJournalClient(transport: $0) }
                model.configure(client: client, side: side); await model.load()
            }
            .onChange(of: phase) {
                if phase == .active { Task { await model.load() } } else { model.invalidate() }
            }
            .onDisappear { model.invalidate() }
    }
    private func selection(_ page: MorningJournalPage) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Journal side", selection: Binding(get: { model.side }, set: { value in notesFocused = false; Task { await model.load(side: value) } })) {
                    Text("Left").tag(Side.left); Text("Right").tag(Side.right)
                }.pickerStyle(.segmented).accessibilityIdentifier("journal.side")
                if typeSize.isAccessibilitySize {
                    Text("Wake date")
                    wakeDatePicker(page).labelsHidden()
                } else { wakeDatePicker(page) }
                Picker("Pattern window", selection: Binding(get: { model.days }, set: { value in notesFocused = false; Task { await model.load(days: value) } })) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }.pickerStyle(.menu)
                Text("Wake dates use \(page.timeZone). Both sides remain available when a sleeper is away.").font(.caption).foregroundStyle(Theme.text2)
            }.padding(16).disabled(model.busy)
        }
    }
    private func wakeDatePicker(_ page: MorningJournalPage) -> some View {
        DatePicker("Wake date", selection: Binding(get: {
            MorningJournalDates.localDate(page.through, timeZone: page.timeZone) ?? .now
        }, set: { value in
            notesFocused = false; Task { await model.load(date: MorningJournalDates.key(value, timeZone: page.timeZone)) }
        }), in: (MorningJournalDates.localDate("1970-01-01", timeZone: page.timeZone) ?? Date(timeIntervalSince1970: 0))...(MorningJournalDates.localDate(page.deviceDate, timeZone: page.timeZone) ?? .now), displayedComponents: .date)
            .environment(\.timeZone, TimeZone(identifier: page.timeZone) ?? .gmt)
            .environment(\.calendar, Calendar(identifier: .gregorian)).accessibilityIdentifier("journal.date")
    }
    private func editor(_ draft: MorningJournalWorkspace.Draft) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("How was your night?").font(.headline)
                Picker("Restfulness", selection: fields.restfulness) {
                    Text("Very low").tag(1); Text("Low").tag(2); Text("Okay").tag(3); Text("Good").tag(4); Text("Great").tag(5)
                }.pickerStyle(.menu).accessibilityIdentifier("journal.restfulness")
                Picker("Temperature comfort", selection: fields.comfort) {
                    Text("Too cold").tag("cold"); Text("Comfortable").tag("comfortable"); Text("Too warm").tag("warm")
                }.pickerStyle(.menu).accessibilityIdentifier("journal.comfort")
                Toggle("Caffeine", isOn: fields.caffeine).accessibilityIdentifier("journal.caffeine")
                Toggle("Alcohol", isOn: fields.alcohol)
                Toggle("Exercise", isOn: fields.exercise)
                Text("Notes for yourself").font(.subheadline)
                TextField("Add a private note", text: fields.notes, axis: .vertical).lineLimit(typeSize.isAccessibilitySize ? 2...4 : 3...8)
                    .focused($notesFocused).accessibilityIdentifier("journal.notes")
                Text("\(fields.wrappedValue.normalized.notes.utf16.count) / 500").font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
                Text("Notes stay on your controller. They are not shared with AI, Apple Health or home integrations.").font(.caption).foregroundStyle(Theme.text2)
                Button("Save check-in") { notesFocused = false; Task { _ = await model.save() } }
                    .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(!model.canSave)
                    .accessibilityIdentifier("journal.save")
                Button("Reset draft") { notesFocused = false; model.resetDraft() }
                    .disabled(!draft.dirty || draft.needsReadback || draft.comparison != nil).accessibilityIdentifier("journal.reset")
                if draft.original.record != nil {
                    Button("Delete check-in", role: .destructive) { confirmDelete = true }.disabled(!model.canSave).accessibilityIdentifier("journal.delete")
                }
                if let record = draft.original.record {
                    Text("\(record.origin == "free-sleep" ? "Imported check-in" : "Controller check-in") · original timezone \(record.timeZone)")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                Text("Unsaved drafts stay separate for each side and wake date while this screen is open.").font(.caption).foregroundStyle(Theme.text2)
            }.padding(16).disabled(model.busy)
        }
    }
    private func comparisonCard(_ saved: MorningJournalSelection) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Saved entry", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                if let record = saved.record {
                    ComfortValueRow("Restfulness", value: "\(record.fields.restfulness) / 5")
                    ComfortValueRow("Comfort", value: record.fields.comfort.capitalized)
                    Text("Caffeine: \(record.fields.caffeine ? "Yes" : "No") · Alcohol: \(record.fields.alcohol ? "Yes" : "No") · Exercise: \(record.fields.exercise ? "Yes" : "No")").font(.footnote)
                    Text(record.fields.notes.isEmpty ? "No saved note." : record.fields.notes).font(.footnote).textSelection(.enabled)
                } else { Text("No check-in is currently saved for this date.") }
                Button("Use saved entry") { model.resolve(keepDraft: false) }.accessibilityIdentifier("journal.useSaved")
                Button("Keep my draft") { model.resolve(keepDraft: true) }.accessibilityIdentifier("journal.keepDraft")
                Text("Keeping your draft does not send it. Save only after reviewing the values below.").font(.caption).foregroundStyle(Theme.text2)
            }.padding(16).disabled(model.busy)
        }
    }
    private func entries(_ page: MorningJournalPage) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Saved check-ins").font(.headline)
                if page.entries.isEmpty { Text("No check-ins in this window.").foregroundStyle(Theme.text2) }
                ForEach(page.entries, id: \.date) { entry in
                    Button { notesFocused = false; Task { await model.load(date: entry.date) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.date).font(.subheadline)
                            if let fields = entry.record?.fields {
                                Text("Restfulness \(fields.restfulness)/5 · \(fields.comfort.capitalized)").font(.caption).foregroundStyle(Theme.text2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.disabled(model.busy).accessibilityIdentifier("journal.entry.\(entry.date)")
                }
            }.padding(16)
        }
    }
}

struct MorningJournalPatternsCard: View {
    let patterns: MorningJournalPage.Patterns
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your patterns").font(.headline)
                Text("Latest \(patterns.recentEntries) check-ins").font(.subheadline).foregroundStyle(Theme.text2)
                ComfortValueRow("Average restfulness", value: patterns.averageRestfulness.map { $0.formatted(.number.precision(.fractionLength(1))) + " / 5" } ?? "Unavailable")
                ComfortValueRow("Too warm / too cold", value: "\(patterns.warmCount) / \(patterns.coldCount)")
                ForEach(patterns.cohorts, id: \.source) { cohort in
                    Divider().overlay(Theme.border1)
                    Text(cohort.source == "sleepypod" ? "Controller bed presence" : "Imported bed presence").font(.subheadline.bold())
                    Text("\(cohort.matchedDates) matched dates · \(cohort.excludedDates) excluded · \(cohort.timeZone ?? "Timezone unavailable")").font(.caption).foregroundStyle(Theme.text2)
                    if cohort.associations.isEmpty {
                        Text(cohort.status == "ready" ? "Not enough matched dates for a habit comparison." : "This source is unavailable for comparison.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    ForEach(cohort.associations, id: \.habit) { item in
                        Text("\(item.habit.capitalized): \(item.presenceDifferenceMinutes.formatted(.number.sign(strategy: .always()).precision(.fractionLength(0)))) minutes of bed presence with this habit (\(item.withCount) dates with / \(item.withoutCount) without).")
                            .font(.footnote).accessibilityIdentifier("journal.association.\(cohort.source).\(item.habit)")
                    }
                }
                Text(patterns.note).font(.caption).foregroundStyle(Theme.text2)
            }.padding(16)
        }
    }
}
