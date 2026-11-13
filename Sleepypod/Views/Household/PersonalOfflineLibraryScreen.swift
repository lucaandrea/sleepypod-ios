import SwiftUI

/// Saved contents are looked up again on every render so account withdrawal also hides open details.
struct PersonalOfflineLibraryScreen: View {
    @Bindable var model: PersonalOfflineLibraryWorkspace
    @State private var confirmRemoval = false
    private var readable: PersonalOfflineLibrary? { model.enabled ? model.library : nil }

    var body: some View {
        Form {
            if !model.enabled {
                Text("This saved account view is closed. Reopen your personal account to continue.")
            } else {
            Section {
                Label("Saved on this device", systemImage: "lock.doc").font(.headline)
                Text(model.connection.session.person.displayName).font(.title2.bold())
                Text("Read your last downloaded recordings and operating week, even without a connection. Each section shows when it was saved.")
                    .font(.footnote).foregroundStyle(Theme.text1)
                Text("These copies cannot confirm the bed’s current state, later schedule changes or an alarm firing.")
                    .font(.footnote).foregroundStyle(Theme.text1).accessibilityIdentifier("personalOffline.meaning")
            }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(Theme.text1).accessibilityIdentifier("personalOffline.error")
                    Button("Read saved copy again") { model.restore() }.disabled(!model.enabled)
                }
            }
            if let library = readable, !library.recordings.isEmpty || library.week != nil {
                if !library.recordings.isEmpty {
                    Section("Recordings") {
                        ForEach(library.recordings) { saved in
                            NavigationLink { recordingList(saved.query.kind) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(saved.query.kind.title).font(.headline)
                                    Text("\(saved.records.count) saved · \(synced(saved.syncedAt))").font(.footnote).foregroundStyle(Theme.text1)
                                }
                            }.accessibilityIdentifier("personalOffline.kind.\(saved.id)")
                        }
                    }
                }
                if let week = library.week {
                    Section("Weekly plan") {
                        NavigationLink { operatingWeek } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Last read operating week").font(.headline)
                                Text(synced(week.syncedAt)).font(.footnote).foregroundStyle(Theme.text1)
                            }
                        }.accessibilityIdentifier("personalOffline.week")
                        Text("A saved draft is never shown as an operating routine. One-time wake changes are not included in this copy.")
                            .font(.footnote).foregroundStyle(Theme.text1)
                    }
                }
                Section {
                    Button("Remove this saved copy", role: .destructive) { confirmRemoval = true }
                        .accessibilityIdentifier("personalOffline.remove")
                    Text("Removes this account’s saved readings on this device. Your account stays paired and the Pod’s data stays in place.")
                        .font(.footnote).foregroundStyle(Theme.text1)
                }
            } else if model.error == nil {
                Section {
                    Text("No readings saved yet").font(.headline).accessibilityIdentifier("personalOffline.empty")
                    Text("When connected, open Your recordings or review your operating week. Successfully loaded sections will be saved here automatically.")
                        .foregroundStyle(Theme.text1)
                }
            }
            }
        }
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Saved readings").navigationBarTitleDisplayMode(.inline)
        .task { model.restore() }
        .alert("Remove this saved copy?", isPresented: $confirmRemoval) {
            Button("Remove saved copy", role: .destructive) { model.remove() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("You can download it again when connected. This does not change the bed or its schedules.") }
    }

    private func synced(_ milliseconds: Int64) -> String {
        "Last synced \(Date(timeIntervalSince1970: Double(milliseconds) / 1_000).formatted(date: .abbreviated, time: .shortened))"
    }
    private func recordingList(_ kind: PersonalHistoryQuery.Kind) -> some View {
        Form {
            if let saved = readable?.recordings.first(where: { $0.query.kind == kind }) {
                Section {
                    Text(synced(saved.syncedAt)).font(.headline)
                    Text("Requested range: \(PersonalHistoryPresentation.date(saved.query.startsAt)) to \(PersonalHistoryPresentation.date(saved.query.endsAt)). Times are shown in \(TimeZone.current.identifier).")
                        .font(.footnote).foregroundStyle(Theme.text1)
                    if saved.hasMore { Text("This is a partial downloaded list. Connect and open Your recordings to fetch more.").foregroundStyle(Theme.text1) }
                    if saved.records.isEmpty { Text("The last fetch returned no recordings in this range. That does not mean zero sleep.") }
                }
                Section("Downloaded recordings") {
                    ForEach(saved.records) { record in
                        NavigationLink { recording(record.id, kind: kind) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(PersonalHistoryPresentation.date(record.startsAt)).font(.headline)
                                Text(PersonalHistoryPresentation.summary(record.payload)).foregroundStyle(Theme.text1)
                            }
                        }.accessibilityIdentifier("personalOffline.record.\(record.id)")
                    }
                }
            }
        }.privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Saved \(kind.title.lowercased())").navigationBarTitleDisplayMode(.inline)
    }
    private func recording(_ identifier: String, kind: PersonalHistoryQuery.Kind) -> some View {
        Form {
            if let saved = readable?.recordings.first(where: { $0.query.kind == kind }),
               let record = saved.records.first(where: { $0.id == identifier }) {
                Section {
                    Text(synced(saved.syncedAt)).font(.headline)
                    Text("Full interval · \(PersonalHistoryPresentation.date(record.startsAt)) to \(PersonalHistoryPresentation.date(record.endsAt))")
                        .foregroundStyle(Theme.text1)
                    PersonalHistoryPayloadView(payload: record.payload)
                }
                Section("Recording source") {
                    Text("Recorded on the \(record.recordedSide.rawValue) · \(PersonalHistoryPresentation.mode(record.attribution.mode))")
                    Text("Attribution follows the reviewed arrangement. It does not identify the sleeper from biometrics. Presence is not confirmed sleep, and movement is not sleep stages.")
                        .font(.footnote).foregroundStyle(Theme.text1)
                }
            }
        }.privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Saved recording").navigationBarTitleDisplayMode(.inline)
    }
    private var operatingWeek: some View {
        Form {
            if let week = readable?.week {
                Section {
                    Text(synced(week.syncedAt)).font(.headline)
                    Text("Controller time zone: \(week.timeZone). These were the operating routines when downloaded; reconnect to check changes or one-time wake overrides.")
                        .font(.footnote).foregroundStyle(Theme.text1)
                }
                ForEach(DayOfWeek.allCases) { day in
                    Section(day.displayName + " bedtime") {
                        PersonalRoutineDetails(day: day, draft: week.routines.first { $0.dayOfWeek == day }?.draft, unit: week.temperatureUnit)
                    }
                }
            }
        }.privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Saved operating week").navigationBarTitleDisplayMode(.inline)
    }
}
