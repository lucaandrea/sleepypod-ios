import SwiftUI

struct NightAnomalyScreen: View {
    @Environment(NightAnomalyStore.self) private var store
    @Environment(HealthSyncService.self) private var health
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var phase
    @State private var confirmingDelete = false
    private var scope: String { (health.watchReferenceContext + [settings.timeZone]).joined(separator: "|") }
    private var calendar: Calendar { SleepCalendar.calendar(timeZone: settings.timeZone) }

    var body: some View {
        @Bindable var store = store
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Learn your normal", systemImage: "waveform.path").font(.title2.bold())
                    Text("A local nearest-neighbour model learns your recorded sleep duration and timing. Consistent, well-covered Watch readings can add awake time, heart rate, HRV and breathing.")
                        .foregroundStyle(Theme.text2)
                    Label(store.status, systemImage: store.verified ? "checkmark.seal" : "clock").foregroundStyle(Theme.cool)
                    Text("A difference is a prompt to reflect, not a diagnosis or proof of poor sleep. No notifications or bed adjustments are sent.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }.cardStyle()
                if let message = store.message { Text(message).font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("anomaly.message") }
                if store.busy { ProgressView("Working with local records…") }
                Button(store.loaded ? "Refresh Health nights" : "Check my Health nights", systemImage: "arrow.clockwise") {
                    Task { await store.refresh(health: health, calendar: calendar, expectedScope: scope) }
                }.buttonStyle(CapsuleButtonStyle(weight: .filled)).disabled(store.busy || APIBackend.current.isDemo)
                    .accessibilityIdentifier("anomaly.refresh")
                if !health.enabled || !health.preferences.readSleep {
                    NavigationLink("Allow Apple Health sleep history") { HealthAccessView() }
                }
                if store.loaded {
                    reviewCard
                    if !store.exclusions.isEmpty {
                        DisclosureGroup("Excluded recordings") {
                            ForEach(store.exclusions.keys.sorted(), id: \.self) { reason in
                                Text("\(store.exclusions[reason] ?? 0) · \(reason)").font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }.cardStyle()
                    }
                }
                if let model = store.model { modelCard(model) }
                if let assessment = store.assessment, store.verified { assessmentCard(assessment) }
                Text("Reads the last 180 days; fits the most recent 40–90 reviewed nights from one source. At least 20 earlier nights fit the baseline, and 20 later reference nights calibrate the score. These are engineering minimums, not proof of clinical accuracy. A baseline older than 45 days cannot score a new night.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }.padding(16)
        }.background(Theme.background).navigationTitle("Night baseline").navigationBarTitleDisplayMode(.inline)
            .task(id: scope) { store.activate(scope: scope) }
            .onChange(of: phase) { if phase != .active { store.cancel() } }
            .onDisappear { store.cancel() }
            .confirmationDialog("Delete this iPhone’s learned baseline?", isPresented: $confirmingDelete) {
                Button("Delete baseline", role: .destructive) { store.delete() }
            } message: { Text("Your Apple Health records stay in Health.") }
    }

    private var reviewCard: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 14) {
            Text("Review actual complete nights").font(.headline)
            if !store.sources.isEmpty {
                Picker("Health source", selection: $store.selectedSource) {
                    ForEach(store.sources, id: \.self) { source in Text(store.sourceName(source)).tag(source) }
                }.pickerStyle(.menu).disabled(store.busy)
            }
            Text("\(store.candidates.count) candidates · \(store.selected.count) reviewed · 40 needed")
                .font(.subheadline).foregroundStyle(Theme.cool).accessibilityIdentifier("anomaly.counts")
            Text("Confirm only genuine nights recorded from bedtime to waking. Leave partial nights, naps and test sessions off. Long recordings still need your review; software cannot know whether you wore the device all night.")
                .font(.footnote).foregroundStyle(Theme.text2)
            Toggle("Include matched Watch vitals", isOn: $store.includeVitals).disabled(store.busy)
            Text("Optional: requires consistently covered Watch measurements on both training and later reference nights. If readings are sparse, leave this off to learn sleep and timing only. Missing vitals are never filled in.")
                .font(.caption).foregroundStyle(Theme.text2)
            DisclosureGroup("Choose nights") {
                ForEach(store.candidates) { night in
                    Toggle(isOn: Binding(get: { store.reviewed[night.id] == night.reviewToken }, set: { store.review(night, confirmed: $0) })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(night.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone)))
                            Text("\(Int(night.values["sleepMinutes"] ?? 0)) min sleep · \(Int((night.coverage * 100).rounded()))% recorded coverage")
                                .font(.caption).foregroundStyle(Theme.text2)
                        }
                    }.disabled(store.busy)
                }
            }
            Button("Train my baseline", systemImage: "brain") { Task { await store.train(currentScope: { scope }) } }
                .buttonStyle(CapsuleButtonStyle(weight: .filled)).disabled(!store.canTrain || APIBackend.current.isDemo)
                .accessibilityIdentifier("anomaly.train")
        }.cardStyle()
    }

    private func modelCard(_ model: NightAnomalyModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Saved model", systemImage: "internaldrive").font(.headline)
            Text(model.sourceName).foregroundStyle(Theme.text2)
            Text("\(model.trainingNights) training nights · \(model.calibrationNights) later reference nights").font(.subheadline)
            ForEach(model.features, id: \.self) { feature in Label(NightAnomalyModel.featureNames[feature] ?? feature, systemImage: "checkmark").font(.caption).foregroundStyle(Theme.cool) }
            Text("Trained \(model.trainedAt.formatted(date: .abbreviated, time: .shortened)) · \(model.algorithm)").font(.caption).foregroundStyle(Theme.text2)
            Button("Delete local baseline", role: .destructive) { confirmingDelete = true }.disabled(store.busy)
        }.cardStyle()
    }

    private func assessmentCard(_ result: NightAnomalyModel.Assessment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(result.unusual ? "Different from your reference nights" : "Within your reference pattern", systemImage: result.unusual ? "sparkle.magnifyingglass" : "moon.stars")
                .font(.headline).foregroundStyle(result.unusual ? Theme.amber : Theme.green)
            if let night = store.nights.first(where: { $0.id == result.nightID }) { Text(night.end.formatted(date: .abbreviated, time: .omitted)).font(.subheadline) }
            Text("More different than \(Int(result.referencePercentile * 100))% of the later reference nights. This is an empirical ranking, not the probability of a health condition.")
                .font(.footnote).foregroundStyle(Theme.text2)
            ForEach(result.differences.prefix(3)) { difference in
                VStack(alignment: .leading, spacing: 4) {
                    Text(NightAnomalyModel.featureNames[difference.feature] ?? difference.feature).font(.subheadline.bold())
                    Text("This night \(formatted(difference.value, feature: difference.feature)) · baseline centre \(formatted(difference.reference, feature: difference.feature))")
                        .font(.caption).foregroundStyle(Theme.text2)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.cool.opacity(0.1), in: .rect(cornerRadius: 12))
            }
        }.cardStyle().accessibilityIdentifier("anomaly.result")
    }

    private func formatted(_ value: Double, feature: String) -> String {
        switch feature {
        case "midpointMinutes": return String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
        case "sleepMinutes": return "\(Int(value)) min"
        case "awakeFraction": return "\(Int(value * 100))%"
        case "heartRate": return String(format: "%.0f bpm", value)
        case "hrvSDNN": return String(format: "%.0f ms", value)
        case "respiratoryRate": return String(format: "%.1f /min", value)
        default: return String(format: "%.1f", value)
        }
    }
}
