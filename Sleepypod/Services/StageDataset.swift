import Foundation

/// The user's Watch-labelled nights as training rows: one row per 5-minute epoch the Watch staged, plus what
/// the rules and the bundled challenger said for the same night so a personal model is scored against both.
struct StageDataset: Sendable {
    typealias Block = WatchComparison.StageSample

    struct LabeledRow: Sendable, Equatable {
        let start: Date
        let values: [String: Double]
        let label: SleepAnalyzer.SleepStage
    }

    struct Night: Sendable, Identifiable {
        /// The pod's sleep record id.
        let id: Int
        let enteredBed: Date
        let leftBed: Date
        let watch: [Block]
        /// Labelled epochs only, in time order.
        let rows: [LabeledRow]
        /// The on-device rules on the 5-minute grid, what a personal model would replace.
        let rules: [Block]
        /// The bundled challenger's blocks; empty when it is not bundled or had no heart rate.
        let challenger: [Block]
    }

    static let minimumNights = 5
    static let minimumEpochs = 300
    static let minimumWatchSleep: TimeInterval = 2 * 3600
    static let daysBack = 90

    let contract: StageFeatures.Contract
    /// Oldest first.
    let nights: [Night]

    var labeledEpochs: Int { nights.reduce(0) { $0 + $1.rows.count } }
    var isTrainable: Bool { shortfall == nil }
    /// Why training is not offered yet, in the user's terms.
    var shortfall: String? {
        if nights.count < Self.minimumNights {
            return "Needs \(Self.minimumNights) nights with Apple Watch sleep; found \(nights.count)."
        }
        if labeledEpochs < Self.minimumEpochs {
            return "Needs \(Self.minimumEpochs) Watch-staged epochs; found \(labeledEpochs)."
        }
        return nil
    }

    /// The class index a model emits, in `StageScore.order`: wake 0, light 1, deep 2, rem 3.
    static func classIndex(_ stage: SleepAnalyzer.SleepStage) -> Int64 {
        Int64(StageScore.order.firstIndex(of: stage) ?? 1)
    }

    /// The first Watch block containing the epoch midpoint labels it, the rule `StageScore.score` uses, so
    /// training labels and scoring labels can never disagree. Epochs no block covers are dropped.
    static func label(_ epochs: [StageChallenger.FeatureEpoch], watch: [Block]) -> [LabeledRow] {
        epochs.compactMap { epoch in
            let mid = epoch.start.addingTimeInterval(StageChallenger.epochSeconds / 2)
            return watch.first { mid >= $0.start && mid < $0.end }.map { LabeledRow(start: epoch.start, values: epoch.values, label: $0.stage) }
        }
    }

    /// Seconds the Watch called asleep (anything but wake).
    static func watchSleepSeconds(_ blocks: [Block]) -> TimeInterval {
        blocks.filter { $0.stage != .wake }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Each night held out once, with every other night's rows as the training set (not yet oversampled).
    func leaveOneNightOut() -> [(heldOut: Night, training: [LabeledRow])] {
        nights.map { night in (night, nights.filter { $0.id != night.id }.flatMap(\.rows)) }
    }

    var allRows: [LabeledRow] { nights.flatMap(\.rows) }

    /// Create ML has no class weights, so rare classes are duplicated in inverse proportion to their frequency,
    /// capped so no class ends up with more rows than the commonest one. Deterministic: copies follow the originals.
    static func oversampled(_ rows: [LabeledRow]) -> [LabeledRow] {
        var counts: [SleepAnalyzer.SleepStage: Int] = [:]
        for row in rows { counts[row.label, default: 0] += 1 }
        guard let largest = counts.values.max(), largest > 0 else { return rows }
        var result = rows
        for (stage, count) in counts where count < largest {
            let copies = largest / count - 1
            guard copies > 0 else { continue }
            let members = rows.filter { $0.label == stage }
            for _ in 0..<copies { result.append(contentsOf: members) }
        }
        return result
    }

    /// Classified 5-minute blocks for rows, for scoring a classifier against the Watch.
    static func blocks(_ rows: [LabeledRow], classifier: any SleepStageClassifying) throws -> [Block] {
        try StageChallenger.classify(rows.map { StageChallenger.FeatureEpoch(start: $0.start, values: $0.values) }, with: classifier)
    }
}

/// Builds the dataset from the pod and Health, one night at a time, with progress for the UI.
@MainActor
struct StageDatasetBuilder {
    let api: SleepypodProtocol
    let health: HealthSyncService
    let side: Side
    let demo: Bool
    let challenger: StageChallenger.Availability

    func build(contract: StageFeatures.Contract, progress: @MainActor (Int, Int) -> Void) async throws -> StageDataset {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -StageDataset.daysBack, to: end) ?? end
        let records = try await HealthSyncService.sleepRecords(api: api, side: side, start: start, end: end)
            .filter { $0.side == side.rawValue && HealthSyncService.isSyncable($0) && $0.leftBedDate <= end }
        let candidates = Self.longestPerDay(records)
        let calibration = try? await api.getCalibrationStatus(side: side)
        var nights: [StageDataset.Night] = []
        for (index, record) in candidates.enumerated() {
            progress(index, candidates.count)
            try Task.checkCancellation()
            if let night = try await night(record, contract: contract, calibrationQuality: calibration?.piezo?.qualityScore ?? 0) {
                nights.append(night)
            }
        }
        progress(candidates.count, candidates.count)
        return StageDataset(contract: contract, nights: nights)
    }

    /// The day's longest sleep record, as the Night page picks it, oldest first.
    static func longestPerDay(_ records: [SleepRecord]) -> [SleepRecord] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.enteredBedDate) }
        return byDay.values.compactMap { $0.max { $0.sleepPeriodSeconds < $1.sleepPeriodSeconds } }
            .sorted { $0.enteredBedDate < $1.enteredBedDate }
    }

    private func night(_ record: SleepRecord, contract: StageFeatures.Contract, calibrationQuality: Double) async throws -> StageDataset.Night? {
        let enteredBed = record.enteredBedDate, leftBed = record.leftBedDate
        let vitals = try await api.getVitals(side: side, start: enteredBed, end: leftBed)
            .filter { $0.side == side.rawValue && $0.date >= enteredBed && $0.date < leftBed }
        let movement = try await api.getMovement(side: side, start: enteredBed, end: leftBed).filter { $0.side == side.rawValue }
        let analyzer = SleepAnalyzer()
        let filtered = analyzer.filterOutliers(vitals: vitals)
        guard !filtered.isEmpty else { return nil }
        analyzer.analyze(vitals: vitals, movement: movement, calibrationQuality: calibrationQuality)
        let starts = StageComparison.epochStarts(enteredBed: enteredBed, leftBed: leftBed)
        let rules = StageComparison.gridded(SleepStagesTimelineView.segments(analyzer.stages).map {
            StageDataset.Block(start: $0.start, end: $0.end, stage: $0.stage)
        }, starts: starts)

        let watch: [StageDataset.Block]
        if demo {
            watch = StageComparison.demoWatch(record: record, pod: rules)
        } else {
            let margin = HealthSyncService.watchSearchMargin
            let samples = await health.sleepSamples(start: enteredBed.addingTimeInterval(-margin), end: leftBed.addingTimeInterval(margin))
            let stages = StageComparison.watchStages(samples.map {
                (source: StageComparison.HealthSource($0), value: $0.value, start: $0.startDate, end: $0.endDate)
            })
            watch = WatchComparison.session(for: enteredBed, end: leftBed, in: WatchComparison.sessions(stages))?.samples ?? []
        }
        guard StageDataset.watchSleepSeconds(watch) >= StageDataset.minimumWatchSleep else { return nil }

        let rows = StageDataset.label(StageFeatures.rows(contract: contract, enteredBed: enteredBed, leftBed: leftBed,
                                                         vitals: filtered, movement: movement), watch: watch)
        guard !rows.isEmpty else { return nil }
        var challengerBlocks: [StageDataset.Block] = []
        if let classifier = challenger.classifier {
            let features = StageChallenger.features(enteredBed: enteredBed, leftBed: leftBed, vitals: filtered, movement: movement)
            challengerBlocks = (try? StageChallenger.classify(features, with: classifier)) ?? []
        }
        return StageDataset.Night(id: record.id, enteredBed: enteredBed, leftBed: leftBed, watch: watch, rows: rows,
                                  rules: rules, challenger: challengerBlocks)
    }
}
