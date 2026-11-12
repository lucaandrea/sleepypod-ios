import SwiftUI
import FreeSleepKit

struct LearningJourneyLink: View {
    var body: some View {
        NavigationLink { LearningJourneyScreen() } label: {
            SettingsRow("Learning journey", subtitle: "Stages, your baseline and temperature learning", icon: "brain.head.profile", iconColor: Theme.purple, chevron: true)
        }.cardStyle(vertical: 0, horizontal: 0).buttonStyle(.plain).accessibilityIdentifier("learning.open")
    }
}

struct LearningJourneyScreen: View {
    @Environment(StageModelStore.self) private var stages
    @Environment(NightAnomalyStore.self) private var baseline
    @Environment(HealthSyncService.self) private var health
    @Environment(SettingsManager.self) private var settings
    @Environment(UserProfile.self) private var profile
    @Environment(\.scenePhase) private var phase
    @State private var workspace = LearningJourneyWorkspace()
    @State private var selectedSide: Side?
    @State private var displayedBaselineScope: String?
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("household.boundaryRevision") private var boundary = ""
    private var side: Side { selectedSide ?? profile.defaultSide }
    private var baselineScope: String { (health.watchReferenceDataContext + [settings.timeZone]).joined(separator: "|") }
    private var scope: String { "\(owner)|\(backend)|\(address)|\(host)|\(boundary)|\(baselineScope)|\(side)|\(phase)" }

    var body: some View {
        ScrollView {
            if PersonalWorkspaceBoundary.isActive {
                ContentUnavailableView("Private model workspace", systemImage: "person.crop.circle.badge.checkmark",
                    description: Text("Finish your personal setup to use your own learning history. The household owner's models are not shown here."))
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    content(now: timeline.date)
                }
            }
        }.background(Theme.background).navigationTitle("Learning journey").navigationBarTitleDisplayMode(.inline)
            .task(id: scope) {
                workspace.invalidate()
                guard phase == .active, !PersonalWorkspaceBoundary.isActive, !APIBackend.current.isDemo else { return }
                baseline.activate(scope: baselineScope)
                displayedBaselineScope = scope
                let api = HealthSyncService.frozenClient()
                let thermal = try? CoreRESTClient.configured()
                workspace.configure(side: side, stages: { try await api.getStageModel(side: $0) }, thermal: { targetSide in
                    guard APIBackend.current == .sleepypodCore, let thermal else { throw APIError.noBaseURL }
                    return try await CorePersonalComfortClient(transport: thermal).thermalModel(side: targetSide)
                })
                await workspace.refresh()
            }
            .onDisappear { workspace.invalidate() }
    }

    private func content(now: Date) -> some View {
        let demo = APIBackend.current.isDemo
        let showsBaseline = !demo && displayedBaselineScope == scope
        let stage = LearningJourneyStep.stages(inventory: demo ? .init(model: nil, uploadedAt: nil, active: false) : workspace.stages(at: now),
            reviewed: !demo && side == profile.defaultSide && stages.hasCurrentTrainingAudit(side: side) ? stages.confirmedTrainingNights.count : nil,
            required: StageModelStore.minimumNights)
        let personal = LearningJourneyStep.baseline(saved: showsBaseline && baseline.model != nil, verified: showsBaseline && baseline.verified,
            referenceEnd: showsBaseline ? baseline.model?.referenceEnd : nil, trainedAt: showsBaseline ? baseline.model?.trainedAt : nil,
            loaded: showsBaseline && baseline.loaded, reviewed: showsBaseline ? baseline.selected.count : 0, required: NightAnomalyModel.minimumNights, now: now)
        return VStack(alignment: .leading, spacing: 18) {
            if demo { Eyebrow("EXAMPLE · NO PERSONAL TRAINING DATA", color: Theme.amber) }
            VStack(alignment: .leading, spacing: 12) {
                Text("Three kinds of learning. One useful next step.").font(.title2.bold())
                Text("Start with reliable recordings, review real nights, then compare results. Finishing a progress bar never turns on bed control.").foregroundStyle(Theme.text2)
                Picker("Pod model side", selection: Binding(get: { side }, set: { selectedSide = $0 })) {
                    ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("learning.side")
                Text("Pod checks below use \(settings.sideName(for: side)). Personal Health history belongs to this iPhone; stage training uses your usual \(settings.sideName(for: profile.defaultSide)) side.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }.cardStyle()
            learningCard(stage, icon: "moon.stars", color: Theme.purple) {
                NavigationLink("Review stages · \(settings.sideName(for: profile.defaultSide))") { IntelligenceModelsScreen() }
                    .accessibilityIdentifier("learning.stages")
            }
            learningCard(personal, icon: "waveform.path", color: Theme.cool) {
                NavigationLink("Review personal baseline") { NightAnomalyScreen() }.accessibilityIdentifier("learning.baseline")
            }
            learningCard(.temperature(demo ? nil : workspace.thermal(at: now)), icon: "thermometer.medium", color: Theme.green) {
                NavigationLink("Review temperature learning") { PersonalComfortDestination(side: side) }.accessibilityIdentifier("learning.temperature")
                NavigationLink("Study small target changes") { TargetResponseScreen(side: side) }.accessibilityIdentifier("learning.response")
            }
            if let error = workspace.stageError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            if let error = workspace.thermalError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            Button {
                Task { await workspace.refresh() }
            } label: {
                Label(workspace.busy ? "Reading Pod inventory…" : "Refresh Pod model checks", systemImage: "arrow.clockwise")
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
            }.buttonStyle(.bordered).disabled(demo || workspace.busy).accessibilityIdentifier("learning.refresh")
            Text("This page only reads model inventory. It does not request Health access, fit a model, change the selected estimator or adjust the bed. Local models and Pod models are separate.")
                .font(.footnote).foregroundStyle(Theme.text2)
        }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
    }

    private func learningCard<Action: View>(_ step: LearningJourneyStep, icon: String, color: Color, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(step.title, systemImage: icon).font(.headline).foregroundStyle(color)
            Text(step.state).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8).background(color.opacity(0.12), in: .rect(cornerRadius: 14))
            Text(step.purpose).font(.subheadline).foregroundStyle(Theme.text2)
            if let progress = step.progress {
                Text("\(progress.reviewed) / \(progress.required) reviewed nights for fitting").font(.subheadline)
                ProgressView(value: progress.fraction).tint(color).accessibilityLabel("Reviewed nights for fitting")
                Text("Last reviewed selection. Coverage, validation and activation are separate.").font(.caption).foregroundStyle(Theme.text2)
            }
            Divider()
            Text("Your next step").font(.subheadline.bold())
            Text(step.next).font(.subheadline).foregroundStyle(Theme.text2)
            action().buttonStyle(.bordered).frame(minHeight: 44)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle().accessibilityElement(children: .contain)
    }
}
