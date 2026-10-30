import SwiftUI

struct PersonalHistoryScreen: View {
    @Bindable var model: PersonalHistoryWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection: PersonalHistoryRoute?

    var body: some View {
        Form {
            Section {
                Text("Your Pod recordings").font(.headline)
                Text("Attributed to \(model.connection.session.person.displayName) by a reviewed bed arrangement. This does not identify who was in bed from their biometrics.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                Text("Presence is not confirmed sleep. Movement is not sleep stages. Pod HRV is separate from Apple Watch HRV.")
                    .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("history.meaning")
            }
            Section("Show recordings") {
                if typeSize.isAccessibilitySize {
                    Picker("Recording type", selection: $model.kind) { kindOptions }.pickerStyle(.inline)
                    Picker("Time range", selection: $model.window) { windowOptions }.pickerStyle(.inline)
                } else {
                    Picker("Recording type", selection: $model.kind) { kindOptions }.pickerStyle(.segmented)
                    Picker("Time range", selection: $model.window) { windowOptions }.pickerStyle(.segmented)
                }
                if let query = model.query {
                    Text("From \(PersonalHistoryPresentation.date(query.startsAt)) to \(PersonalHistoryPresentation.date(query.endsAt))")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                Text("Times shown in \(TimeZone.current.identifier). Ranges cover the last 7, 30 or 90 complete 24-hour periods.")
                    .font(.caption).foregroundStyle(Theme.text2)
            }.disabled(model.busy || !model.enabled)
            if model.busy { Section { ProgressView("Loading recordings…").accessibilityIdentifier("history.loading") } }
            if let error = model.error { Section { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("history.error") } }
            if model.loaded {
                Section {
                    if model.records.isEmpty {
                        Text("No attributed recordings in this range.").accessibilityIdentifier("history.empty")
                        Text("This does not mean zero sleep or confirm that recording ingestion is active.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    ForEach(model.records) { record in
                        Button { selection = PersonalHistoryRoute(id: record.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(PersonalHistoryPresentation.date(record.startsAt)).font(.headline)
                                Text("Until \(PersonalHistoryPresentation.date(record.endsAt))").font(.caption).foregroundStyle(Theme.text2)
                                Text(PersonalHistoryPresentation.summary(record.payload)).font(.body)
                                Text("Recorded on the \(record.recordedSide.rawValue) · \(PersonalHistoryPresentation.mode(record.attribution.mode))")
                                    .font(.caption).foregroundStyle(Theme.text2)
                            }.padding(.vertical, 4)
                        }.disabled(model.busy).accessibilityIdentifier("history.record.\(record.id)")
                    }
                    if model.nextCursor != nil {
                        Button("Load older recordings") { Task { await model.loadMore() } }
                            .disabled(!model.canLoadMore).accessibilityIdentifier("history.more")
                    }
                } header: {
                    Text("Complete recordings")
                } footer: {
                    Text("Overlapping recordings retain their original start and end. Values are never clipped or prorated to the selected range.")
                }
            }
            if let generated = model.generatedAt {
                Section { Text("Loaded from your Pod · \(PersonalHistoryPresentation.date(generated))").font(.caption).foregroundStyle(Theme.text2) }
            }
        }
        .modifier(PersonalHistoryAccessCheck(model: model))
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Your recordings").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Refresh recordings", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .disabled(model.busy || !model.enabled).accessibilityIdentifier("history.refresh")
        } }
        .navigationDestination(item: $selection) { route in PersonalHistoryDetailScreen(model: model, recordId: route.id) }
        .task { if !model.loaded { await model.refresh() } }
        .onChange(of: model.kind) { Task { await model.refresh() } }
        .onChange(of: model.window) { Task { await model.refresh() } }
        .onChange(of: scenePhase) {
            if scenePhase != .active { model.suspend() }
            else if selection == nil { Task { await model.refresh() } }
        }
        .onChange(of: selection) { if selection == nil && !model.loaded { Task { await model.refresh() } } }
        .onDisappear { if selection == nil { model.suspend() } }
    }
    private var kindOptions: some View {
        ForEach(PersonalHistoryQuery.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
    }
    private var windowOptions: some View {
        ForEach(PersonalHistoryWorkspace.Window.allCases, id: \.self) { window in Text("\(window.rawValue) days").tag(window) }
    }
}
