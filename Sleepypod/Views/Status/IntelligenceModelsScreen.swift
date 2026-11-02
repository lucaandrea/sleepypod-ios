import SwiftUI

struct IntelligenceModelsScreen: View {
    @Environment(StageModelStore.self) private var models
    @Environment(HealthSyncService.self) private var health
    @Environment(UserProfile.self) private var profile
    private var builder: StageDatasetBuilder {
        StageDatasetBuilder(api: APIBackend.current.createClient(), health: health, side: profile.defaultSide,
                            demo: APIBackend.current.isDemo, challenger: StageChallenger.bundled)
    }
    private var disabled: Bool { APIBackend.current.isDemo || !health.enabled || !health.preferences.readSleep }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Your models, explained", systemImage: "brain.head.profile").font(.title2.bold())
                    Text("Sleep stages estimate what happened overnight. A personal baseline spots nights that differ from your recent pattern. Temperature Autopilot runs separately on your Pod.")
                        .foregroundStyle(Theme.text2)
                    Text("Current sleep estimates: \(models.active?.title ?? "Rule-based")").font(.subheadline).foregroundStyle(Theme.cool)
                    if models.source != .rules {
                        Button("Use rule-based estimates") { models.choose(.rules) }.disabled(models.isTraining)
                    }
                }.cardStyle()
                NavigationLink { NightAnomalyScreen() } label: {
                    SettingsRow("Personal night baseline", subtitle: "Learn your pattern and compare later nights", icon: "chart.xyaxis.line", iconColor: Theme.cool, chevron: true)
                }.cardStyle(vertical: 0, horizontal: 0).accessibilityIdentifier("models.anomaly")
                researchModel
                if disabled {
                    NavigationLink { HealthAccessView() } label: {
                        Label("Allow Apple Health sleep history", systemImage: "heart").frame(maxWidth: .infinity, alignment: .leading)
                    }.cardStyle()
                }
                StageTrainingReadinessCard(side: profile.defaultSide, builder: builder, disabled: disabled)
                ForEach(StageModelKind.allCases) { kind in personalModel(kind) }
                if let error = models.trainingError { Text(error).foregroundStyle(Theme.amber).font(.footnote) }
                if models.isTraining { ProgressView(models.trainingStatus ?? "Training locally", value: models.trainingProgress) }
                Text("All model training and inference on this page stay on this iPhone. Model outputs are experimental wellness estimates, not diagnoses. No model here can move, heat or vibrate your bed.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }.padding(16)
        }.background(Theme.background).navigationTitle("Intelligence models").navigationBarTitleDisplayMode(.inline)
            .task { if !APIBackend.current.isDemo { await models.refreshPodModel(api: APIBackend.current.createClient(), side: profile.defaultSide) } }
    }

    private var researchModel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sleep-stage research model", systemImage: "moon.stars").font(.headline)
            Text("Core ML · random forest").font(.subheadline).foregroundStyle(Theme.purple)
            switch StageChallenger.bundled {
            case .ready(_, let card):
                Label("Loaded and self-tested", systemImage: "checkmark.seal").foregroundStyle(Theme.green)
                Text("Version \(card.version)").font(.caption).foregroundStyle(Theme.text2)
            case .notBundled:
                Text("The research model is missing from this installation.").foregroundStyle(Theme.amber)
            case .failed(let reason):
                Text("Model validation failed: \(reason)").foregroundStyle(Theme.amber)
            }
            Text("Trained on 31 participants’ wrist motion and heart rate with laboratory sleep labels. A mattress records different signals, so this model is a comparison baseline, not a validated personal classifier.")
                .font(.footnote).foregroundStyle(Theme.text2)
            Link("Dataset and research", destination: URL(string: "https://physionet.org/content/sleep-accel/1.0.0/")!).font(.footnote)
        }.cardStyle().accessibilityIdentifier("models.research")
    }

    private func personalModel(_ kind: StageModelKind) -> some View {
        let card = models.card(for: kind)
        let eligible = models.isEligible(kind)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Personal \(kind.title.lowercased())").font(.headline)
            Text(card == nil ? "Needs complete, reviewed Pod + Watch nights" : eligible ? "Passed personal comparison gates" : "Trained · comparison gates not passed")
                .font(.subheadline).foregroundStyle(eligible ? Theme.green : Theme.text2)
            if let metrics = card?.metrics?.lono {
                Text("\(metrics.nights ?? 0) held-out nights · agreement κ \(metrics.kappa.map { String(format: "%.2f", $0) } ?? "unavailable")")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
            Text("Training holds out each full night in turn. Selection requires better agreement than the rules and research baseline, by at least 0.05 κ, and wins on most nights. Watch estimates are a comparison source, not clinical truth.")
                .font(.footnote).foregroundStyle(Theme.text2)
            Button(card == nil ? "Train \(kind.title.lowercased())" : "Retrain \(kind.title.lowercased())", systemImage: "brain") {
                Task { await models.train(kind, builder: builder) }
            }.buttonStyle(CapsuleButtonStyle(weight: .filled))
                .disabled(disabled || !StageTrainer.isAvailable || models.isTraining || !models.hasCurrentTrainingAudit(side: profile.defaultSide) || models.confirmedTrainingNights.count < StageModelStore.minimumNights)
            if eligible {
                Button(models.source.kind == kind ? "Selected for sleep estimates" : "Use for sleep estimates") { models.choose(.forKind(kind)) }
                    .disabled(models.source.kind == kind || models.isTraining)
            }
            if !StageTrainer.isAvailable { Text("Personal stage training requires a physical iPhone.").font(.caption).foregroundStyle(Theme.text2) }
        }.cardStyle()
    }
}
