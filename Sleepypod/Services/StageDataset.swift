import Foundation
import CryptoKit

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
        var recordIDs: [Int] = []

        /// Confirmation belongs to these exact signals and labels, not just a date that can be reprocessed.
        func reviewToken(contract: StageFeatures.Contract) -> String? {
            let document: [String: Any] = [
                "contract": contract.rawValue, "records": recordIDs.sorted(),
                "start": enteredBed.timeIntervalSince1970, "end": leftBed.timeIntervalSince1970,
                "rows": rows.map { ["start": $0.start.timeIntervalSince1970, "values": $0.values,
                                      "label": StageDataset.classIndex($0.label)] as [String: Any] },
                "watch": watch.map { [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970,
                                        Double(StageDataset.classIndex($0.stage))] }
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    static let minimumNights = 5
    static let minimumEpochs = 300
    static let daysBack = 90

    let contract: StageFeatures.Contract
    /// Oldest first.
    let nights: [Night]
    var exclusions: [StageTrainingExclusion] = []

    var labeledEpochs: Int { nights.reduce(0) { $0 + $1.rows.count } }
    var isTrainable: Bool { shortfall == nil }
    /// Why training is not offered yet, in the user's terms.
    var shortfall: String? {
        if nights.count < Self.minimumNights {
            return "Needs \(Self.minimumNights) complete nights with matching Pod and Watch coverage; found \(nights.count). \(exclusions.count) recordings or night groups were excluded. Review the coverage details below."
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
        let settings = try await api.getSettings()
        guard TimeZone(identifier: settings.timeZone) != nil else {
            throw StageTrainer.TrainingError.notEnoughData("The Pod's timezone is unavailable. Reconnect before checking training nights.")
        }
        let calendar = SleepCalendar.calendar(timeZone: settings.timeZone)
        let records = try await HealthSyncService.sleepRecords(api: api, side: side, start: start, end: end)
            .filter { $0.side == side.rawValue }
        let candidates = StageTrainingNight.grouped(records, calendar: calendar)
        let calibration = try? await api.getCalibrationStatus(side: side)
        var nights: [StageDataset.Night] = []
        var exclusions: [StageTrainingExclusion] = []
        Log.general.notice("Stage dataset: \(candidates.count) candidate nights over \(StageDataset.daysBack) days")
        for (index, candidate) in candidates.enumerated() {
            progress(index, candidates.count)
            try Task.checkCancellation()
            let started = Date()
            do {
                if let issue = candidate.issue(now: end) { throw Rejection.coverage(issue) }
                let accepted = try await night(candidate, contract: contract, calibrationQuality: calibration?.piezo?.qualityScore ?? 0)
                nights.append(accepted)
                Log.general.notice("Stage dataset: night \(index + 1)/\(candidates.count) kept, \(accepted.rows.count) labelled epochs, \(Int(Date().timeIntervalSince(started))) s")
            } catch Rejection.coverage(let reason) {
                exclusions.append(StageTrainingExclusion(date: candidate.date, recordIDs: candidate.records.map(\.id), reason: reason))
            }
        }
        Log.general.notice("Stage dataset: \(nights.count) nights, \(nights.reduce(0) { $0 + $1.rows.count }) labelled epochs")
        progress(candidates.count, candidates.count)
        return StageDataset(contract: contract, nights: nights, exclusions: exclusions)
    }

    private enum Rejection: Error { case coverage(String) }

    private func night(_ candidate: StageTrainingNight, contract: StageFeatures.Contract, calibrationQuality: Double) async throws -> StageDataset.Night {
        let enteredBed = candidate.start, leftBed = candidate.end
        let presence = StageTrainingCoverage.merged(candidate.presence ?? [], within: candidate.window)
        let vitals = try await api.getVitals(side: side, start: enteredBed, end: leftBed)
            .filter { sample in sample.side == side.rawValue && presence.contains { sample.date >= $0.start && sample.date < $0.end } }
        let movement = try await api.getMovement(side: side, start: enteredBed, end: leftBed)
            .filter { sample in sample.side == side.rawValue && presence.contains { sample.date >= $0.start && sample.date < $0.end } }
        let analyzer = SleepAnalyzer()
        let filtered = analyzer.filterOutliers(vitals: vitals)
        let heartRateWindows = filtered.filter { $0.heartRate?.isFinite == true }.map { DateInterval(start: $0.date, duration: 60) }
        if let issue = StageTrainingCoverage.issue(heartRateWindows, within: candidate.window) { throw Rejection.coverage("Pod heart rate: \(issue)") }
        let movementWindows = movement.map { DateInterval(start: $0.date, duration: 60) }
        if let issue = StageTrainingCoverage.issue(movementWindows, within: candidate.window) { throw Rejection.coverage("Pod movement: \(issue)") }
        analyzer.analyze(vitals: vitals, movement: movement, calibrationQuality: calibrationQuality)
        let starts = StageComparison.epochStarts(enteredBed: enteredBed, leftBed: leftBed)
        let rules = StageComparison.gridded(SleepStagesTimelineView.segments(analyzer.stages).map {
            StageDataset.Block(start: $0.start, end: $0.end, stage: $0.stage)
        }, starts: starts)

        let watch: [StageDataset.Block]
        if demo {
            throw Rejection.coverage("Demo recordings are excluded from training")
        } else {
            let margin = HealthSyncService.watchSearchMargin
            let samples = await health.sleepSamples(start: enteredBed.addingTimeInterval(-margin), end: leftBed.addingTimeInterval(margin))
            let stages = StageComparison.watchStages(samples.map {
                (source: StageComparison.HealthSource($0), value: $0.value, start: $0.startDate, end: $0.endDate)
            })
            watch = WatchComparison.session(for: enteredBed, end: leftBed, in: WatchComparison.sessions(stages))?.samples ?? []
        }
        guard !StageTrainingCoverage.hasConflictingStages(watch) else { throw Rejection.coverage("Watch stages conflict") }
        if let issue = StageTrainingCoverage.issue(watch.map { DateInterval(start: $0.start, end: $0.end) }, within: candidate.window) {
            throw Rejection.coverage("Apple Watch: \(issue)")
        }

        let features = StageFeatures.rows(contract: contract, enteredBed: enteredBed, leftBed: leftBed, vitals: filtered, movement: movement)
            .filter { epoch in presence.contains { epoch.start >= $0.start && epoch.start.addingTimeInterval(StageChallenger.epochSeconds) <= $0.end } }
        let rows = StageDataset.label(features, watch: watch)
        if let issue = StageTrainingCoverage.issue(rows.map { DateInterval(start: $0.start, duration: StageChallenger.epochSeconds) }, within: candidate.window) {
            throw Rejection.coverage("Matched training epochs: \(issue)")
        }
        var challengerBlocks: [StageDataset.Block] = []
        if let classifier = challenger.classifier {
            let features = StageChallenger.features(enteredBed: enteredBed, leftBed: leftBed, vitals: filtered, movement: movement)
            challengerBlocks = (try? StageChallenger.classify(features, with: classifier)) ?? []
        }
        return StageDataset.Night(id: candidate.id, enteredBed: enteredBed, leftBed: leftBed, watch: watch, rows: rows,
                                  rules: rules, challenger: challengerBlocks, recordIDs: candidate.records.map(\.id))
    }
}
