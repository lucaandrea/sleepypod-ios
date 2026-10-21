import SwiftUI
import Charts

/// One night's hypnograms from the Apple Watch, the pod's rules and the experimental challenger model on a
/// shared time axis, with the pod and the model each scored against the Watch.
struct StageComparisonView: View {
    @Environment(HealthSyncService.self) private var health
    @Environment(StageModelStore.self) private var stageModels
    let side: Side
    @State private var confirmDelete: StageModelKind?
    @State private var debugTrainingStarted = false
    @State private var modelShareItems: [URL] = []
    @State private var record: SleepRecord
    @State private var nights: [SleepRecord] = []
    @State private var comparisons: [Int: StageComparison] = [:]
    /// The touched time, shared so every lane marks the same moment.
    @State private var selection: Date?
    @State private var exportProgress: (done: Int, total: Int)?
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var exportError: String?

    private typealias Block = StageComparison.Block
    private let order: [SleepAnalyzer.SleepStage] = [.wake, .rem, .light, .deep]
    private static let nightsBack = 30

    init(record: SleepRecord, side: Side) {
        _record = State(initialValue: record)
        self.side = side
    }

    private var isDemo: Bool { APIBackend.current.isDemo }
    private var challenger: StageChallenger.Availability { StageChallenger.bundled }
    private var needsHealthAccess: Bool { !isDemo && (!health.enabled || !health.preferences.readSleep) }
    private var comparison: StageComparison? { comparisons[record.id] }
    private var loader: StageComparisonLoader {
        StageComparisonLoader(api: APIBackend.current.createClient(), health: health, side: side, demo: isDemo, challenger: challenger,
                              personal: isDemo ? Self.demoPersonal : stageModels.personal, podModel: isDemo ? nil : stageModels.podModel)
    }
    /// Demo mode shows both personal lanes without a trained model behind them.
    private static let demoPersonal: [StageModelKind: StageChallenger.Availability] = [.logistic: .notBundled, .forest: .notBundled]
    private var builder: StageDatasetBuilder {
        StageDatasetBuilder(api: APIBackend.current.createClient(), health: health, side: side, demo: isDemo, challenger: challenger)
    }
    /// Cards with personal lanes are cached per night; a new model needs a reload, keyed by its versions.
    private var personalVersions: String {
        (StageModelKind.allCases.map { stageModels.card(for: $0)?.version ?? "-" } + [stageModels.podModel?.version ?? "-"]).joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                nightPicker.padding(.horizontal, 4)
                experimentalNote
                if needsHealthAccess { healthAccessCard }
                if let comparison {
                    lanesCard(comparison)
                    if comparison.hasWatchData {
                        scoresCard(comparison)
                    } else {
                        ContentUnavailableView("No Apple Watch sleep", systemImage: "applewatch",
                                               description: Text(health.readError.map { "Health read failed: \($0)" }
                                                   ?? "No Apple Watch sleep stages overlap this night, so there is nothing to score against. Wear your Watch to bed with Sleep tracking on."))
                            .cardStyle()
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                personalCard
                modelCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Stage models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let exportProgress {
                    Text("\(exportProgress.done)/\(exportProgress.total)").font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text2)
                        .accessibilityLabel("Scoring night \(exportProgress.done) of \(exportProgress.total)")
                } else {
                    Button("Share agreement", systemImage: "square.and.arrow.up") { Task { await shareAgreement() } }
                        .disabled(nights.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .sheet(isPresented: Binding(get: { !modelShareItems.isEmpty }, set: { if !$0 { modelShareItems = [] } })) {
            ShareSheet(items: modelShareItems)
        }
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .alert("Training didn't finish", isPresented: Binding(get: { stageModels.trainingError != nil }, set: { if !$0 { stageModels.trainingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(stageModels.trainingError ?? "") }
        .task { await loadNights() }
        .task {
            guard let kind = DebugRoute.trainStageModel, !isDemo, !stageModels.isTraining, !debugTrainingStarted else { return }
            debugTrainingStarted = true
            await stageModels.train(kind, builder: builder)
        }
        .onChange(of: personalVersions) { comparisons = [:] }
        .confirmationDialog("Delete this model?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let kind = confirmDelete { stageModels.delete(kind) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("Stages go back to the rules if this model was in use. You can train it again any time.") }
        .task(id: "\(record.id)-\(personalVersions)") {
            selection = nil
            // Capture the night before awaiting: switching nights cancels this
            // task, and a late result must not be cached, or cached under the new night.
            let night = record
            guard comparisons[night.id] == nil else { return }
            let comparison = await loader.load(night)
            guard !Task.isCancelled else { return }
            comparisons[night.id] = comparison
        }
    }

    // MARK: Header

    private func nightLabel(_ night: SleepRecord) -> String {
        "\(night.enteredBedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(night.bedtimeFormatted)"
    }

    private var nightPicker: some View {
        Menu {
            Picker("Night", selection: Binding(get: { record.id }, set: { id in
                if let night = nights.first(where: { $0.id == id }) { record = night }
            })) {
                ForEach(nights) { night in Text(nightLabel(night)).tag(night.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(nightLabel(record))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text2)
        }
        .accessibilityLabel("Night, \(nightLabel(record))")
        .accessibilityIdentifier("stageNightPicker")
    }

    private var experimentalNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("EXPERIMENTAL · NOT MEDICAL", color: Theme.amber)
            Text("Three ways of staging the same night. The challenger is a research model run on this iPhone; neither it, the pod nor the Watch is a medical device, and none should guide treatment.")
                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var healthAccessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow sleepypod to read Sleep in Apple Health to compare with your Watch.")
                .font(.subheadline).foregroundStyle(Theme.text1).fixedSize(horizontal: false, vertical: true)
            NavigationLink { HealthAccessView() } label: {
                Text("Set up Apple Health").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.red)
            }
        }
        .cardStyle()
    }

    // MARK: Lanes

    /// Hypnogram rows, deepest at the bottom, as on the Watch page.
    private static func row(_ stage: SleepAnalyzer.SleepStage) -> Double {
        switch stage {
        case .wake: 3
        case .rem: 2
        case .light: 1
        case .deep: 0
        }
    }

    private func modelPlaceholder(_ comparison: StageComparison) -> String? {
        switch comparison.modelStatus {
        case .notBundled: "Model not bundled"
        case .failed(let message): "Model unavailable: \(message)"
        case .ready: comparison.model.isEmpty ? "No pod heart rate this night" : nil
        }
    }

    private func lanesCard(_ comparison: StageComparison) -> some View {
        let watch = WatchComparison.merged(comparison.watch, maxGap: 0)
        let model = WatchComparison.merged(comparison.model, maxGap: 0)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("STAGES")
                Spacer()
                if let selection {
                    Text(readout(at: selection, watch: watch, pod: comparison.pod, model: model))
                        .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text1)
                }
            }
            lane("APPLE WATCH", blocks: watch, score: nil, comparison: comparison,
                 placeholder: watch.isEmpty ? (needsHealthAccess ? "Health access needed" : "No Watch sleep this night") : nil)
            lane("POD (RULES)", blocks: comparison.pod, score: comparison.podScore, comparison: comparison,
                 placeholder: comparison.podError != nil ? "Pod stages unavailable" : comparison.pod.isEmpty ? "No pod stages this night" : nil)
            lane("CHALLENGER MODEL (EXPERIMENTAL)", blocks: model, score: comparison.modelScore, comparison: comparison,
                 placeholder: modelPlaceholder(comparison), showsTime: comparison.personal.isEmpty)
            ForEach(StageModelKind.allCases) { kind in
                if let personal = comparison.personal[kind] {
                    lane(kind.title.uppercased(), blocks: WatchComparison.merged(personal.blocks, maxGap: 0), score: personal.score,
                         comparison: comparison, placeholder: personal.error.map { "Model unavailable: \($0)" }
                            ?? (personal.blocks.isEmpty ? "No pod heart rate this night" : nil),
                         showsTime: comparison.podModel == nil && kind == StageModelKind.allCases.last(where: { comparison.personal[$0] != nil }), isModel: true)
                }
            }
            if let pod = comparison.podModel {
                lane("POD MODEL · \(stageModels.podModel?.title.uppercased() ?? "")", blocks: WatchComparison.merged(pod.blocks, maxGap: 0), score: pod.score,
                     comparison: comparison, placeholder: pod.error.map { "Model unavailable: \($0)" } ?? (pod.blocks.isEmpty ? "No pod heart rate this night" : nil),
                     showsTime: true, isModel: true)
            }
            legend
        }
        .cardStyle()
    }

    private func lane(_ title: String, blocks: [Block], score: StageScore?, comparison: StageComparison,
                      placeholder: String?, showsTime: Bool = false, isModel: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Eyebrow(title, size: 10)
                if isModel { StageSourceBadge(.model(""), compact: true) }
                Spacer(minLength: 8)
                if let score {
                    Text("κ \(Self.kappaText(score.kappa)) · \(Self.percent(score.accuracy))")
                        .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text1)
                }
            }
            Chart {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    RectangleMark(xStart: .value("Start", block.start), xEnd: .value("End", block.end),
                                  yStart: .value("Row", Self.row(block.stage) - 0.36), yEnd: .value("Row", Self.row(block.stage) + 0.36))
                        .foregroundStyle(block.stage.displayColor)
                }
                if let selection {
                    RuleMark(x: .value("Selected", selection)).foregroundStyle(Theme.text3).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: comparison.start...comparison.end)
            .chartYScale(domain: -0.5...3.5)
            .chartXSelection(value: $selection)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 1, 2, 3]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.border1)
                    AxisValueLabel {
                        if let row = value.as(Double.self), let stage = order.first(where: { Self.row($0) == row }) {
                            Text(stage.label).font(.mono(10, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    if showsTime {
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.hour()).font(.mono(10, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
            }
            .frame(height: showsTime ? 92 : 76)
            .overlay {
                if let placeholder {
                    Text(placeholder).font(.footnote).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.card, in: Capsule())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title.capitalized). \(placeholder ?? summary(blocks))")
        }
    }

    private func readout(at date: Date, watch: [Block], pod: [Block], model: [Block]) -> String {
        func text(_ blocks: [Block]) -> String { WatchComparison.stage(at: date, in: blocks)?.label ?? "—" }
        return "\(date.formatted(date: .omitted, time: .shortened))  ·  \(text(watch)) / \(text(pod)) / \(text(model))"
    }

    private func summary(_ blocks: [Block]) -> String {
        blocks.isEmpty ? "none recorded" : order.map { stage in
            let seconds = blocks.filter { $0.stage == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            return "\(stage.label) \(DisplayTime.duration(Int(seconds)))"
        }.joined(separator: ", ")
    }

    private var legend: some View {
        HStack(spacing: 0) {
            ForEach(order, id: \.self) { stage in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(stage.displayColor).frame(width: 7, height: 7)
                    Text(stage.label)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text2)
        .accessibilityHidden(true)
    }

    // MARK: Scores

    private static func kappaText(_ kappa: Double?) -> String { kappa.map { String(format: "%.2f", $0) } ?? "—" }
    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func scoresCard(_ comparison: StageComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("AGREEMENT WITH APPLE WATCH")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("κ").gridColumnAlignment(.trailing)
                    Text("ACCURACY").gridColumnAlignment(.trailing)
                    Text("EPOCHS").gridColumnAlignment(.trailing)
                }
                .font(.mono(10, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                scoreRow("Pod (rules)", comparison.podScore)
                scoreRow("Challenger", comparison.modelScore)
                ForEach(StageModelKind.allCases) { kind in
                    if let personal = comparison.personal[kind] { scoreRow(kind.title, personal.score) }
                }
                if let pod = comparison.podModel { scoreRow(stageModels.podModel?.title ?? "Pod model", pod.score) }
            }
            Text("Scored per 5-minute epoch against the Watch's stage at its midpoint. κ (Cohen's kappa) is 0 at chance and 1 when every epoch agrees.")
                .font(.footnote).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func scoreRow(_ title: String, _ score: StageScore?) -> some View {
        GridRow {
            Text(title).font(.subheadline).foregroundStyle(Theme.text1)
            Text(Self.kappaText(score?.kappa))
            Text(score.map { Self.percent($0.accuracy) } ?? "—")
            Text(score.map { "\($0.epochs)" } ?? "—")
        }
        .font(.mono(13, relativeTo: .footnote)).foregroundStyle(Theme.text1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "\(title): kappa \(Self.kappaText($0.kappa)), accuracy \(Self.percent($0.accuracy)), \($0.epochs) epochs" }
                            ?? "\(title): not scored")
    }

    // MARK: Personal models

    private var personalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow("PERSONAL MODELS")
                StageSourceBadge(.model("Core ML"), compact: false)
                Spacer()
            }
            Text("Trained on this iPhone from your own nights, with the Watch as the label. Scored leave-one-night-out against the Watch, beside the rules and the challenger on the same epochs.")
                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            podRow
            if stageModels.isTraining {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(stageModels.trainingStatus ?? "Training…").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text1)
                        Spacer()
                        Text("\(Int((stageModels.trainingProgress * 100).rounded()))%").font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text2)
                    }
                    ProgressView(value: stageModels.trainingProgress).tint(Theme.cool)
                    Text("Reads each night's vitals and movement from the pod and its stages from Health, then fits the model once per held-out night. Keep the app open.")
                        .font(.footnote).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Theme.cool.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            if let report = stageModels.lastReport, !stageModels.isTraining { reportCard(report) }
            ForEach(StageModelKind.allCases) { kind in personalRow(kind) }
            if !StageTrainer.isAvailable && !isDemo {
                Text("Training needs an iPhone; the simulator has no Create ML.").font(.footnote).foregroundStyle(Theme.text3)
            }
            if isDemo {
                Text("Demo mode shows synthesized personal lanes; connect a pod and wear your Watch to train real ones.")
                    .font(.footnote).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    /// What the last training run found, in the same κ terms as the lanes above.
    private func reportCard(_ report: StageTrainingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last run · \(report.kind.title.lowercased())").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text1)
                Spacer()
                Text("\(report.nights) nights · \(report.epochs) epochs").font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text3)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("κ").gridColumnAlignment(.trailing)
                    Text("ACCURACY").gridColumnAlignment(.trailing)
                    Text("NIGHTS WON").gridColumnAlignment(.trailing)
                }
                .font(.mono(10, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                reportRow(report.kind.title, report.pooled, won: "\(report.nightsWon) of \(report.nights)")
                reportRow("Pod (rules)", report.rules, won: "")
                if let challenger = report.challenger { reportRow("Challenger", challenger, won: "") }
            }
            let eligible = stageModels.isEligible(report.kind)
            Text(eligible
                 ? "Clears the bar: choose it under Settings → On-device analysis → Sleep stages from."
                 : "Not yet eligible: needs κ \(String(format: "%.2f", StageModelStore.kappaMargin)) above both and a majority of nights won. More Watch nights help most.")
                .font(.footnote).foregroundStyle(eligible ? Theme.green : Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border1, lineWidth: 1))
    }

    private func reportRow(_ title: String, _ score: StageScore?, won: String) -> some View {
        GridRow {
            Text(title).font(.subheadline).foregroundStyle(Theme.text1)
            Text(Self.kappaText(score?.kappa))
            Text(score.map { Self.percent($0.accuracy) } ?? "—")
            Text(won)
        }
        .font(.mono(13, relativeTo: .footnote)).foregroundStyle(Theme.text1)
    }

    /// The model stored on the pod, trained on a Mac in seconds; the phone evaluates it without training.
    private var podRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pod model").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text1)
                Spacer()
                if let model = stageModels.podModel {
                    Text(model.title.lowercased()).font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text2)
                    if stageModels.source == .pod { Text("· in use").font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.green) }
                } else {
                    Text("none").font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                }
            }
            if let model = stageModels.podModel {
                Text("Trained on a Mac from the pod's nights (\(model.version)). Leave-one-night-out κ \(Self.kappaText(model.metrics?["lono"]?.kappa)) over \(model.metrics?["lono"]?.nights ?? 0) nights. Choose it under Settings → On-device analysis → Sleep stages from.")
                    .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Label(stageModels.podActive ? "Pod stages nights with this model" : "Pod uses rules",
                      systemImage: stageModels.podActive ? "checkmark.circle" : "list.bullet.rectangle")
                    .font(.caption).foregroundStyle(stageModels.podActive ? Theme.green : Theme.text3)
            } else {
                Text(stageModels.podError ?? "Nothing stored on the pod yet. Train on a Mac with scripts/train-personal-models.py and it appears here.")
                    .font(.footnote).foregroundStyle(stageModels.podError == nil ? Theme.text3 : Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            Button("Refresh from pod", systemImage: "arrow.triangle.2.circlepath") {
                Task { await stageModels.refreshPodModel(api: APIBackend.current.createClient(), side: side) }
            }
            .buttonStyle(.bordered).font(.subheadline).disabled(isDemo)
        }
        .padding(.vertical, 4)
    }

    private func personalRow(_ kind: StageModelKind) -> some View {
        let card = stageModels.card(for: kind)
        let eligible = stageModels.isEligible(kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text1)
                Spacer()
                if let card {
                    Text(eligible ? "eligible" : "trained").font(.mono(11, relativeTo: .caption2))
                        .foregroundStyle(eligible ? Theme.green : Theme.text2)
                    if stageModels.source.kind == kind {
                        Text("· in use").font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.green)
                    }
                    Text(card.trainedAt.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
                        .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                } else {
                    Text("not trained").font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text3)
                }
            }
            if let metrics = card?.metrics, let lono = metrics.lono {
                Text("Leave-one-night-out κ \(Self.kappaText(lono.kappa)) over \(lono.nights ?? 0) nights · rules κ \(Self.kappaText(metrics.rules?.kappa))"
                     + (metrics.challenger?.kappa.map { " · challenger κ \(Self.kappaText($0))" } ?? "")
                     + " · won \(metrics.nightsWon ?? 0) of \(lono.nights ?? 0)")
                    .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if !eligible {
                    Text("Needs κ at least \(String(format: "%.2f", StageModelStore.kappaMargin)) above both and a majority of nights before it can stage your sleep.")
                        .font(.footnote).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button(card == nil ? "Train" : "Retrain") {
                    Haptics.light()
                    Task { await stageModels.train(kind, builder: builder) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.cool)
                .disabled(stageModels.isTraining || isDemo || !StageTrainer.isAvailable)
                if card != nil {
                    Button("Share model", systemImage: "square.and.arrow.up") { modelShareItems = stageModels.shareableFiles(for: kind) }
                        .buttonStyle(.bordered).disabled(stageModels.isTraining || stageModels.shareableFiles(for: kind).isEmpty)
                    Button("Delete", role: .destructive) { confirmDelete = kind }
                        .buttonStyle(.bordered).disabled(stageModels.isTraining)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: Model card

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("CHALLENGER MODEL")
                Spacer()
                Text(challenger.version.map { "v\($0)" } ?? (isBundledButFailed ? "unavailable" : "not bundled"))
                    .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text2)
            }
            if let card = challenger.card {
                if let kappa = card.metrics?.loso?.kappa {
                    Text("Trained on \(card.training?.subjects.map(String.init) ?? "—") sleep-lab nights: agreement κ \(Self.kappaText(kappa)) (leave-one-out).")
                }
                if let kappa = card.metrics?.pod?.kappa {
                    Text("On the developer's pod against an Apple Watch\(card.metrics?.pod?.nights.map { " (\($0) nights)" } ?? ""): κ \(Self.kappaText(kappa)), where the pod's rules agree at about chance.")
                }
                if let limitations = card.limitations { Text(limitations).foregroundStyle(Theme.text3) }
            } else if case .failed(let message) = challenger {
                Text(message)
            } else {
                Text("This build doesn't include the model, so its lane stays empty.")
            }
            ForEach(StageChallenger.acknowledgements, id: \.self) { Text($0).foregroundStyle(Theme.text3) }
        }
        .font(.footnote).foregroundStyle(Theme.text2)
        .fixedSize(horizontal: false, vertical: true)
        .cardStyle()
    }

    private var isBundledButFailed: Bool {
        if case .failed = challenger { return true }
        return false
    }

    // MARK: Data

    private func loadNights() async {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -Self.nightsBack, to: end) ?? end
        let records = (try? await HealthSyncService.sleepRecords(api: APIBackend.current.createClient(), side: side, start: start, end: end)) ?? []
        var kept = records.filter { $0.side == side.rawValue && HealthSyncService.isSyncable($0) && $0.leftBedDate <= end }
        if !kept.contains(where: { $0.id == record.id }) { kept.append(record) }
        nights = kept.sorted { $0.enteredBedDate > $1.enteredBedDate }
    }

    /// Scores every night in the picker, oldest first, and shares only the de-identified summary.
    private func shareAgreement() async {
        let ordered = nights.sorted { $0.enteredBedDate < $1.enteredBedDate }
        exportProgress = (0, ordered.count)
        defer { exportProgress = nil }
        var results: [StageComparison] = []
        for night in ordered {
            if let cached = comparisons[night.id] {
                results.append(cached)
            } else {
                let loaded = await loader.load(night)
                comparisons[night.id] = loaded
                results.append(loaded)
            }
            exportProgress = (results.count, ordered.count)
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(StageAgreementExport.filename)
            try StageAgreementExport(nights: results, modelVersion: challenger.version).data().write(to: url, options: .atomic)
            exportURL = url
            showShare = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}
