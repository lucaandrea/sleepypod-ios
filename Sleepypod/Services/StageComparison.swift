import Foundation
import HealthKit

/// Agreement with a reference hypnogram, ported from `scoreAgainstReference` in sleepypod-core's
/// `src/lib/sleep-stages.ts` so the app and the pod score the same way: each epoch is compared with the
/// first reference block that contains its midpoint, and epochs no block covers are not counted.
struct StageScore: Sendable, Equatable {
    /// Row and column order of `confusion` and `recall`, matching the model's class labels.
    static let order: [SleepAnalyzer.SleepStage] = [.wake, .light, .deep, .rem]

    /// Epochs whose midpoint falls inside a reference block.
    let epochs: Int
    /// Fraction of those epochs whose stage matches the reference (0–1).
    let accuracy: Double
    /// Cohen's kappa; nil when chance agreement is total.
    let kappa: Double?
    /// confusion[reference][predicted], in `order`.
    let confusion: [[Int]]
    /// Fraction of each reference stage's epochs predicted correctly; nil when the reference has none.
    let recall: [Double?]

    static func score(_ epochs: [WatchComparison.StageSample], reference: [WatchComparison.StageSample]) -> StageScore? {
        var predicted = [Int](repeating: 0, count: order.count)
        var actual = [Int](repeating: 0, count: order.count)
        var confusion = [[Int]](repeating: [Int](repeating: 0, count: order.count), count: order.count)
        var covered = 0
        var matches = 0
        for epoch in epochs {
            let mid = epoch.start.addingTimeInterval(epoch.end.timeIntervalSince(epoch.start) / 2)
            guard let ref = reference.first(where: { mid >= $0.start && mid < $0.end }),
                  let refIndex = order.firstIndex(of: ref.stage), let predIndex = order.firstIndex(of: epoch.stage) else { continue }
            covered += 1
            predicted[predIndex] += 1
            actual[refIndex] += 1
            confusion[refIndex][predIndex] += 1
            if refIndex == predIndex { matches += 1 }
        }
        guard covered > 0 else { return nil }
        let total = Double(covered)
        let accuracy = Double(matches) / total
        let chance = order.indices.reduce(0.0) { $0 + (Double(predicted[$1]) / total) * (Double(actual[$1]) / total) }
        return StageScore(epochs: covered, accuracy: accuracy,
                          kappa: chance == 1 ? nil : (accuracy - chance) / (1 - chance),
                          confusion: confusion,
                          recall: order.indices.map { actual[$0] == 0 ? nil : Double(confusion[$0][$0]) / Double(actual[$0]) })
    }
}

/// One night's three hypnograms (Apple Watch, the pod's rules, the challenger model) and how the latter two
/// agree with the Watch, scored per 5-minute epoch.
struct StageComparison: Sendable {
    typealias Block = WatchComparison.StageSample

    enum ModelStatus: Sendable, Equatable {
        case ready
        case notBundled
        case failed(String)
    }

    let start: Date
    let end: Date
    /// 5-minute epochs in the bed window, the denominator both lanes are scored over.
    let epochs: Int
    let watch: [Block]
    let pod: [Block]
    let podError: String?
    let podScore: StageScore?
    let model: [Block]
    let modelStatus: ModelStatus
    let modelScore: StageScore?
    /// The personal models' lanes, by kind; absent when that model is not trained.
    var personal: [StageModelKind: PersonalLane] = [:]
    /// The pod's stored model run over the night, when one is loaded.
    var podModel: PersonalLane?

    struct PersonalLane: Sendable, Equatable {
        let blocks: [Block]
        let score: StageScore?
        let error: String?
        let version: String
    }

    var hasWatchData: Bool { !watch.isEmpty }

    /// Starts of the whole 5-minute epochs from `enteredBed`; a trailing partial epoch is dropped.
    static func epochStarts(enteredBed: Date, leftBed: Date) -> [Date] {
        let night = leftBed.timeIntervalSince(enteredBed)
        guard night >= StageChallenger.epochSeconds else { return [] }
        return (0..<Int((night / StageChallenger.epochSeconds).rounded(.down))).map {
            enteredBed.addingTimeInterval(Double($0) * StageChallenger.epochSeconds)
        }
    }

    /// The pod's blocks resampled onto the 5-minute grid by the stage at each epoch's midpoint.
    static func gridded(_ blocks: [Block], starts: [Date]) -> [Block] {
        starts.compactMap { start in
            let mid = start.addingTimeInterval(StageChallenger.epochSeconds / 2)
            return blocks.first { mid >= $0.start && mid < $0.end }.map {
                Block(start: start, end: start.addingTimeInterval(StageChallenger.epochSeconds), stage: $0.stage)
            }
        }
    }

    static func build(enteredBed: Date, leftBed: Date, watch: [Block], pod: [Block], podError: String? = nil,
                      model: [Block], modelStatus: ModelStatus) -> StageComparison {
        let starts = epochStarts(enteredBed: enteredBed, leftBed: leftBed)
        let watch = watch.sorted { $0.start < $1.start }
        let pod = pod.sorted { $0.start < $1.start }
        return StageComparison(
            start: min(enteredBed, watch.first?.start ?? enteredBed),
            end: max(leftBed, watch.map(\.end).max() ?? leftBed),
            epochs: starts.count,
            watch: watch,
            pod: pod,
            podError: podError,
            podScore: StageScore.score(gridded(pod, starts: starts), reference: watch),
            model: model,
            modelStatus: modelStatus,
            modelScore: StageScore.score(model, reference: watch))
    }

    // MARK: Apple Watch source

    /// Who wrote a Health sample, reduced to what the Watch filter needs so it can be tested without HealthKit objects.
    struct HealthSource: Sendable, Equatable {
        let bundleIdentifier: String
        let productType: String?
        let deviceModel: String?
        let deviceName: String?

        init(bundleIdentifier: String, productType: String?, deviceModel: String?, deviceName: String?) {
            self.bundleIdentifier = bundleIdentifier
            self.productType = productType
            self.deviceModel = deviceModel
            self.deviceName = deviceName
        }

        init(_ sample: HKSample) {
            self.init(bundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                      productType: sample.sourceRevision.productType,
                      deviceModel: sample.device?.model,
                      deviceName: sample.device?.name)
        }
    }

    /// Only Apple's own Watch staging counts. sleepypod writes the pod's stages into Health, so this app's
    /// samples (and anything on a "sleepypod" device) are rejected first; then the source must be Apple Health
    /// (`com.apple.health…`) on Watch hardware, which leaves out iPhone in-bed samples and third-party sleep apps.
    static func isAppleWatchSleep(_ source: HealthSource, appBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        let bundle = source.bundleIdentifier.lowercased()
        if let app = appBundleID?.lowercased(), !app.isEmpty, bundle == app || bundle.hasPrefix(app + ".") { return false }
        if source.deviceName?.localizedCaseInsensitiveContains("sleepypod") == true { return false }
        guard bundle.hasPrefix("com.apple.health") else { return false }
        return source.productType?.lowercased().hasPrefix("watch") == true
            || source.deviceModel?.localizedCaseInsensitiveContains("watch") == true
    }

    /// AsleepCore → light, AsleepDeep → deep, AsleepREM → rem, Awake → wake; in-bed and unspecified are dropped.
    @MainActor
    static func watchStages(_ samples: [(source: HealthSource, value: Int, start: Date, end: Date)],
                            appBundleID: String? = Bundle.main.bundleIdentifier) -> [Block] {
        samples.filter { isAppleWatchSleep($0.source, appBundleID: appBundleID) }.compactMap { sample in
            HealthSyncService.stage(for: sample.value).map { Block(start: sample.start, end: sample.end, stage: $0) }
        }
    }

    /// The Watch's night that overlaps the bed window most, so a nap or the previous night stays out.
    static func watchNight(_ blocks: [Block], enteredBed: Date, leftBed: Date) -> [Block] {
        func overlap(_ session: WatchComparison.Session) -> TimeInterval {
            min(leftBed, session.end).timeIntervalSince(max(enteredBed, session.start))
        }
        guard let best = WatchComparison.sessions(blocks).max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return [] }
        return best.samples
    }

    // MARK: Demo

    /// A deterministic Watch for demo mode, derived from the pod's stages the way the Watch page's demo is.
    static func demoWatch(record: SleepRecord, pod: [Block]) -> [Block] {
        let epochs = gridded(pod, starts: epochStarts(enteredBed: record.enteredBedDate, leftBed: record.leftBedDate)).map {
            SleepAnalyzer.SleepEpoch(start: $0.start, duration: StageChallenger.epochSeconds, stage: $0.stage,
                                     heartRate: 0, hrv: nil, breathingRate: nil)
        }
        return WatchComparison.demo(record: record, epochs: epochs, vitals: []).watchStages
    }
}

extension StageComparison {
    /// One personal model run over a night's vitals, scored against the Watch like the challenger.
    static func personalLane(_ availability: StageChallenger.Availability, enteredBed: Date, leftBed: Date, vitals: [VitalsRecord],
                             movement: [MovementRecord], watch: [Block]) -> PersonalLane? {
        guard case .ready(let classifier, let card) = availability else {
            if case .failed(let message) = availability { return PersonalLane(blocks: [], score: nil, error: message, version: "") }
            return nil
        }
        guard let contract = StageFeatures.Contract.matching(card.columns) else {
            return PersonalLane(blocks: [], score: nil, error: "Unknown feature contract", version: card.version)
        }
        do {
            let rows = StageFeatures.rows(contract: contract, enteredBed: enteredBed, leftBed: leftBed, vitals: vitals, movement: movement)
            let blocks = try StageChallenger.classify(rows, with: classifier)
            return PersonalLane(blocks: blocks, score: StageScore.score(blocks, reference: watch), error: nil, version: card.version)
        } catch {
            return PersonalLane(blocks: [], score: nil, error: error.localizedDescription, version: card.version)
        }
    }

    /// The pod's portable model over a night's vitals, scored like the others.
    static func podLane(_ model: PortableStageModel, enteredBed: Date, leftBed: Date, vitals: [VitalsRecord],
                        movement: [MovementRecord], watch: [Block]) -> PersonalLane {
        guard let contract = model.contract else { return PersonalLane(blocks: [], score: nil, error: "Unknown feature contract", version: model.version) }
        do {
            let rows = StageFeatures.rows(contract: contract, enteredBed: enteredBed, leftBed: leftBed, vitals: vitals, movement: movement)
            let blocks = try StageChallenger.classify(rows, with: PortableStageClassifier(model: model))
            return PersonalLane(blocks: blocks, score: StageScore.score(blocks, reference: watch), error: nil, version: model.version)
        } catch {
            return PersonalLane(blocks: [], score: nil, error: error.localizedDescription, version: model.version)
        }
    }

    /// Demo mode's stand-in for a trained model: the demo Watch with every sixth block nudged to a neighbour.
    static func demoPersonalLane(kind: StageModelKind, watch: [Block]) -> PersonalLane {
        let blocks = watch.enumerated().map { index, block -> Block in
            guard (index + (kind == .forest ? 3 : 0)) % 6 == 0 else { return block }
            let stage: SleepAnalyzer.SleepStage = switch block.stage {
            case .light: .deep
            case .deep: .light
            case .rem: .light
            case .wake: .light
            }
            return Block(start: block.start, end: block.end, stage: stage)
        }
        return PersonalLane(blocks: blocks, score: StageScore.score(blocks, reference: watch), error: nil, version: "demo")
    }
}

/// The de-identified agreement summary people can share for cross-user model comparison (`stage-challenger-v1`).
/// Nights carry only a relative index: no dates, timestamps, record or device ids, and no raw vitals or movement.
struct StageAgreementExport: Encodable, Equatable {
    static let schemaName = "stage-challenger-v1"
    static let filename = "stage-challenger-v1.json"

    struct Lane: Encodable, Equatable {
        let epochs: Int
        let kappa: Double?
        let accuracy: Double
        let confusion: [[Int]]

        init(_ score: StageScore) {
            epochs = score.epochs
            kappa = score.kappa.map(StageAgreementExport.rounded)
            accuracy = StageAgreementExport.rounded(score.accuracy)
            confusion = score.confusion
        }

        private enum CodingKeys: String, CodingKey { case epochs, kappa, accuracy, confusion }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(epochs, forKey: .epochs)
            try c.encode(kappa, forKey: .kappa)
            try c.encode(accuracy, forKey: .accuracy)
            try c.encode(confusion, forKey: .confusion)
        }
    }

    struct Night: Encodable, Equatable {
        let night: Int
        let epochs: Int
        let podRules: Lane?
        let model: Lane?
        /// Personal models trained on this phone; optional so readers of the schema without them keep working.
        let personalLogistic: Lane?
        let personalForest: Lane?

        init(night: Int, epochs: Int, podRules: Lane?, model: Lane?, personalLogistic: Lane? = nil, personalForest: Lane? = nil) {
            self.night = night
            self.epochs = epochs
            self.podRules = podRules
            self.model = model
            self.personalLogistic = personalLogistic
            self.personalForest = personalForest
        }

        private enum CodingKeys: String, CodingKey { case night, epochs, podRules, model, personalLogistic, personalForest }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(night, forKey: .night)
            try c.encode(epochs, forKey: .epochs)
            try c.encode(podRules, forKey: .podRules)
            try c.encode(model, forKey: .model)
            try c.encodeIfPresent(personalLogistic, forKey: .personalLogistic)
            try c.encodeIfPresent(personalForest, forKey: .personalForest)
        }
    }

    let schema = schemaName
    let modelVersion: String?
    let epochSeconds = Int(StageChallenger.epochSeconds)
    /// Row (Watch) and column (predicted) order of every confusion matrix.
    let stageOrder = StageScore.order.map { $0.rawValue.lowercased() }
    let nights: [Night]

    /// Nights in the order given (oldest first), keeping only those the Watch scored.
    init(nights: [StageComparison], modelVersion: String?) {
        self.modelVersion = modelVersion
        self.nights = nights.filter { $0.podScore != nil || $0.modelScore != nil }.enumerated().map { index, night in
            Night(night: index, epochs: night.epochs, podRules: night.podScore.map(Lane.init), model: night.modelScore.map(Lane.init),
                  personalLogistic: night.personal[.logistic]?.score.map(Lane.init), personalForest: night.personal[.forest]?.score.map(Lane.init))
        }
    }

    private enum CodingKeys: String, CodingKey { case schema, modelVersion, epochSeconds, stageOrder, nights }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(modelVersion, forKey: .modelVersion)
        try c.encode(epochSeconds, forKey: .epochSeconds)
        try c.encode(stageOrder, forKey: .stageOrder)
        try c.encode(nights, forKey: .nights)
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
}

/// Fetches one night's three hypnograms: the pod's stages and vitals from the pod, the Watch's from Health.
@MainActor
struct StageComparisonLoader {
    let api: SleepypodProtocol
    let health: HealthSyncService
    let side: Side
    let demo: Bool
    let challenger: StageChallenger.Availability
    /// Trained personal models to run beside the challenger.
    var personal: [StageModelKind: StageChallenger.Availability] = [:]
    /// The pod's stored model, if the store holds a valid one.
    var podModel: PortableStageModel?

    /// How far either side of the bed window Watch samples are read, so a Watch night that starts early still shows whole.
    static let watchMargin: TimeInterval = 3 * 3600

    func load(_ record: SleepRecord) async -> StageComparison {
        let enteredBed = record.enteredBedDate, leftBed = record.leftBedDate
        var pod: [StageComparison.Block] = []
        var podError: String?
        do {
            pod = try await api.getSleepStages(side: side, sleepRecordId: record.id).blocks.compactMap { block in
                block.sleepStage.map { StageComparison.Block(start: block.startDate, end: block.endDate, stage: $0) }
            }
        } catch {
            podError = error.localizedDescription
        }

        var model: [StageComparison.Block] = []
        var status: StageComparison.ModelStatus
        var vitals: [VitalsRecord] = [], movement: [MovementRecord] = []
        var signalsError: String?
        if challenger.classifier != nil || !personal.isEmpty || podModel != nil {
            do {
                // Outlier-filtered, as the dataset builder trains on and the analyzer infers on; a spike would
                // otherwise shift every z-scored feature and the lane would not reproduce the card's κ.
                vitals = SleepAnalyzer().filterOutliers(vitals: try await api.getVitals(side: side, start: enteredBed, end: leftBed)
                    .filter { $0.side == side.rawValue })
                movement = try await api.getMovement(side: side, start: enteredBed, end: leftBed).filter { $0.side == side.rawValue }
            } catch {
                signalsError = error.localizedDescription
            }
        }
        switch challenger {
        case .ready(let classifier, _):
            if let signalsError {
                status = .failed(signalsError)
            } else {
                do {
                    let features = StageChallenger.features(enteredBed: enteredBed, leftBed: leftBed, vitals: vitals, movement: movement)
                    model = try StageChallenger.classify(features, with: classifier)
                    status = .ready
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
        case .notBundled:
            status = .notBundled
        case .failed(let message):
            status = .failed(message)
        }

        let watch: [StageComparison.Block]
        if demo {
            watch = StageComparison.demoWatch(record: record, pod: pod)
        } else {
            let samples = await health.sleepSamples(start: enteredBed.addingTimeInterval(-Self.watchMargin),
                                                    end: leftBed.addingTimeInterval(Self.watchMargin))
            let stages = StageComparison.watchStages(samples.map {
                (source: StageComparison.HealthSource($0), value: $0.value, start: $0.startDate, end: $0.endDate)
            })
            watch = StageComparison.watchNight(stages, enteredBed: enteredBed, leftBed: leftBed)
        }
        var comparison = StageComparison.build(enteredBed: enteredBed, leftBed: leftBed, watch: watch, pod: pod, podError: podError,
                                               model: model, modelStatus: status)
        if let stored = podModel, !demo {
            comparison.podModel = signalsError.map { StageComparison.PersonalLane(blocks: [], score: nil, error: $0, version: stored.version) }
                ?? StageComparison.podLane(stored, enteredBed: enteredBed, leftBed: leftBed, vitals: vitals, movement: movement, watch: watch)
        }
        for (kind, availability) in personal {
            if demo {
                comparison.personal[kind] = StageComparison.demoPersonalLane(kind: kind, watch: watch)
            } else if let signalsError {
                comparison.personal[kind] = StageComparison.PersonalLane(blocks: [], score: nil, error: signalsError, version: "")
            } else {
                comparison.personal[kind] = StageComparison.personalLane(availability, enteredBed: enteredBed, leftBed: leftBed,
                                                                         vitals: vitals, movement: movement, watch: watch)
            }
        }
        return comparison
    }
}
