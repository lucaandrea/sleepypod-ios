import SwiftUI
import Charts

/// One night's hypnograms from the Apple Watch, the pod's rules and the experimental challenger model on a
/// shared time axis, with the pod and the model each scored against the Watch.
struct StageComparisonView: View {
    @Environment(HealthSyncService.self) private var health
    let side: Side
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
        StageComparisonLoader(api: APIBackend.current.createClient(), health: health, side: side, demo: isDemo, challenger: challenger)
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
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .task { await loadNights() }
        .task(id: record.id) {
            selection = nil
            if comparisons[record.id] == nil { comparisons[record.id] = await loader.load(record) }
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
                 placeholder: modelPlaceholder(comparison), showsTime: true)
            legend
        }
        .cardStyle()
    }

    private func lane(_ title: String, blocks: [Block], score: StageScore?, comparison: StageComparison,
                      placeholder: String?, showsTime: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(title, size: 10)
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
