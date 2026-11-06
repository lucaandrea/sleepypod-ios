import FreeSleepKit
import SwiftUI

struct HealthHRVReviewView: View {
    @Environment(HealthSyncService.self) private var health
    @Environment(SettingsManager.self) private var settings
    @Environment(UserProfile.self) private var profile
    @Environment(\.scenePhase) private var scenePhase
    @State private var review = HealthHRVReviewWorkspace()
    @State private var period = 30
    @State private var days: [Day] = []
    @State private var selectedDays = Set<Date>()
    @State private var confirmRemoval = false
    @State private var operation: Task<Void, Never>?
    private var identity: [String] { OwnerConnection.revision + [settings.podID, profile.defaultSide.rawValue] }
    private var calendar: Calendar { SleepCalendar.calendar(timeZone: settings.timeZone) }
    private var selectedCount: Int { days.filter { selectedDays.contains($0.id) }.reduce(0) { $0 + $1.entries.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introduction
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Review period", selection: $period) {
                        ForEach([7, 30, 90], id: \.self) { Text("Last \($0) days").tag($0) }
                    }.disabled(review.busy)
                    Button("Pause export and read app HRV", systemImage: "heart.text.clipboard", action: read)
                        .disabled(review.busy || health.isSyncing || APIBackend.current.isDemo)
                        .accessibilityIdentifier("health.hrvReviewRead")
                    if review.busy { ProgressView("Checking Apple Health…") }
                    if APIBackend.current.isDemo { Text("Demo mode never reads or removes Health entries.").font(.footnote) }
                }.cardStyle()
                if review.scope != nil {
                    Text("\(review.entries.count) entries without verified SDNN metadata · \(review.retainedSDNN) verified entries kept")
                        .font(.footnote).foregroundStyle(Theme.text2)
                    if review.entries.isEmpty {
                        Text("No matching unverified entries were returned for this Pod side and period. Entries from other sources, other Pod identities or without a device identity are outside this review.")
                            .font(.footnote).accessibilityIdentifier("health.hrvReviewEmpty")
                    } else {
                        selection
                    }
                }
                if review.removedCount > 0 {
                    Text("Removed \(review.removedCount) reviewed entries. HRV export remains paused.")
                        .font(.callout).accessibilityIdentifier("health.hrvReviewRemoved")
                }
                if let error = review.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Theme.background).navigationTitle("Review app HRV").navigationBarTitleDisplayMode(.inline)
        .task { configure() }
        .onChange(of: period) { invalidate() }
        .onChange(of: identity) { invalidate() }
        .onChange(of: health.preferences.hrv) { if health.preferences.hrv { invalidate() } }
        .onChange(of: scenePhase) { if scenePhase == .background { invalidate() } }
        .onDisappear { invalidate() }
        .confirmationDialog("Remove \(review.selected.count) reviewed HRV entries?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove selected entries", role: .destructive, action: remove)
        } message: {
            Text("Removes only the selected sleepypod HRV entries for \(settings.sideName(for: profile.defaultSide)) from Apple Health. They lack verified SDNN metadata; that does not prove every value is wrong. Apple Watch, other apps, verified SDNN and other health types stay untouched. Removal syncs through Health and cannot be undone here.")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Check earlier exports", systemImage: "heart.text.clipboard").font(.headline)
            Text("Pod variability is not Apple Health SDNN. Older exports may not record which metric they used. Review their dates and values before selecting entries to remove.")
            Text("This iPhone reads only this app’s HRV for your linked Pod and \(settings.sideName(for: profile.defaultSide)) side. The Pod can be offline. No entries are selected automatically.")
            Text("Reading this review pauses HRV export. Health may ask for HRV access so sleepypod can remove its own entries; export stays paused. Watch HRV remains available for comparison.")
                .font(.footnote).foregroundStyle(Theme.text2)
        }.cardStyle()
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(selectedDays.count == days.count ? "Clear selection" : "Select listed dates") {
                selectedDays = selectedDays.count == days.count ? [] : Set(days.map(\.id))
            }.disabled(review.busy)
            ForEach(days) { day in
                Toggle(isOn: Binding(get: { selectedDays.contains(day.id) }, set: { selected in
                    if selected { selectedDays.insert(day.id) } else { selectedDays.remove(day.id) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.id, format: Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day())
                        Text("\(day.entries.count) entries · \(day.range) ms").font(.footnote).foregroundStyle(Theme.text2)
                        Text("\(day.first.formatted(Date.FormatStyle(timeZone: calendar.timeZone).hour().minute())) – \(day.last.formatted(Date.FormatStyle(timeZone: calendar.timeZone).hour().minute()))")
                            .font(.caption).foregroundStyle(Theme.text2)
                    }
                }.disabled(review.busy).cardStyle()
            }
            Button("Review removal of \(selectedCount) entries", role: .destructive) {
                review.selected = Set(days.filter { selectedDays.contains($0.id) }.flatMap { $0.entries.map(\.id) })
                confirmRemoval = true
            }.disabled(review.busy || selectedCount == 0).accessibilityIdentifier("health.hrvReviewRemove")
        }
    }

    private func configure() {
        review.context = {
            guard !PersonalWorkspaceBoundary.isActive, !APIBackend.current.isDemo,
                  !settings.podID.isEmpty, !health.preferences.hrv, !health.isSyncing else { return nil }
            return OwnerConnection.revision + [settings.podID, profile.defaultSide.rawValue, String(health.preferences.readVitals)]
        }
    }

    private func read() {
        health.preferences.hrv = false
        selectedDays = []; days = []
        let end = Date.now
        guard let start = calendar.date(byAdding: .day, value: -period, to: end), let source = Bundle.main.bundleIdentifier else { return }
        let scope = HealthHRVScope(source: source, deviceID: "\(settings.podID)-\(profile.defaultSide.rawValue)",
                                   side: profile.defaultSide.rawValue, start: start, end: end)
        operation = Task { await review.read(scope: scope); rebuildDays() }
    }

    private func remove() {
        operation = Task { await review.removeSelected(); selectedDays = []; rebuildDays() }
    }

    private func rebuildDays() {
        days = Dictionary(grouping: review.entries) { calendar.startOfDay(for: $0.start) }
            .map { Day(id: $0.key, entries: $0.value) }.sorted { $0.id > $1.id }
    }

    private func invalidate() {
        operation?.cancel(); review.clear(); days = []; selectedDays = []; confirmRemoval = false
    }

    private struct Day: Identifiable {
        let id: Date
        let entries: [HealthHRVEntry]
        var first: Date { entries.map(\.start).min() ?? id }
        var last: Date { entries.map(\.end).max() ?? id }
        var range: String {
            let values = entries.map(\.milliseconds).filter(\.isFinite)
            guard let low = values.min(), let high = values.max() else { return "Unavailable" }
            return "\(low.formatted(.number.precision(.fractionLength(1))))–\(high.formatted(.number.precision(.fractionLength(1))))"
        }
    }
}
