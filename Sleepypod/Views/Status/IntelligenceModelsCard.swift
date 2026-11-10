import SwiftUI

/// Model inventory comes from loaded artifacts and validation, never a hard-coded healthy count.
struct IntelligenceModelsCard: View {
    @Environment(StageModelStore.self) private var stages
    @Environment(NightAnomalyStore.self) private var anomalies
    @Environment(HealthSyncService.self) private var health
    @Environment(SettingsManager.self) private var settings
    private var scope: String { (health.watchReferenceContext + [settings.timeZone]).joined(separator: "|") }

    var body: some View {
        NavigationLink { LearningJourneyScreen() } label: {
            VStack(alignment: .leading, spacing: 14) {
                Label("On-device intelligence", systemImage: "brain").font(.headline).foregroundStyle(Theme.purple)
                Text(stages.active.map { "Sleep estimates · \($0.title)" } ?? "Sleep estimates · rule-based")
                    .font(.subheadline).foregroundStyle(Theme.text1)
                Text(StageChallenger.bundled.classifier == nil ? "Research classifier unavailable" : "Core ML research classifier loaded")
                    .font(.caption).foregroundStyle(Theme.text2)
                HStack(alignment: .firstTextBaseline) {
                    Text("Personal night baseline").font(.subheadline)
                    Spacer(minLength: 8)
                    Text(anomalies.status).font(.caption).foregroundStyle(anomalies.verified ? Theme.green : Theme.text2)
                }
                Label("Learning journey and model details", systemImage: "chevron.right").font(.subheadline).foregroundStyle(Theme.cool)
            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
        }.buttonStyle(.plain).accessibilityIdentifier("models.open")
            .task(id: scope) { anomalies.activate(scope: scope) }
    }
}
