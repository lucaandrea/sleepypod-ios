import CoreML
import Foundation
#if canImport(CreateML)
import CreateML
import TabularData
#endif

/// The two ojwalch/sleep_classifiers models, trained on the phone with Create ML.
enum StageModelKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case logistic
    case forest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .logistic: "Personal logistic"
        case .forest: "Personal forest"
        }
    }
    /// Pinned to sleepypod-core's personal-models.py so the Mac run and the device fit match. Depth 8 came from a
    /// leave-one-night-out sweep on eleven nights (depth 4 κ 0.21, depth 8 κ 0.26; tree count made no difference).
    var hyperparameters: [String: Double] {
        switch self {
        case .logistic: ["maxIterations": 200, "l2Penalty": 0.01]
        case .forest: ["trees": 200, "maxDepth": 8]
        }
    }
}

/// What a training run found: leave-one-night-out agreement with the Watch for the personal model, the rules
/// and the bundled challenger on the same held-out epochs.
struct StageTrainingReport: Sendable, Equatable {
    let kind: StageModelKind
    let contract: StageFeatures.Contract
    let nights: Int
    let epochs: Int
    let pooled: StageScore?
    let rules: StageScore?
    let challenger: StageScore?
    let perNight: [StageScore?]
    let rulesPerNight: [StageScore?]
    let challengerPerNight: [StageScore?]

    /// Nights where the personal model's κ beat both the rules and the challenger (a missing challenger counts as beaten).
    var nightsWon: Int { wonPerNight.filter { $0 }.count }

    /// The same verdict night by night, in training order.
    var wonPerNight: [Bool] {
        perNight.indices.map { index in
            guard let mine = perNight[index]?.kappa else { return false }
            let rulesKappa = rulesPerNight[index]?.kappa ?? -1
            let challengerKappa = challengerPerNight[index]?.kappa ?? -1
            return mine > rulesKappa && mine > challengerKappa
        }
    }

    func evaluation(_ score: StageScore?) -> StageChallenger.Card.Evaluation {
        .init(epochs: score?.epochs, kappa: score?.kappa, accuracy: score?.accuracy, nights: nights)
    }
}

struct StageTrainingResult: Sendable {
    let report: StageTrainingReport
    let card: StageChallenger.Card
    /// The compiled model directory, installed in place.
    let modelURL: URL
    let cardURL: URL
}

/// Fits a personal model from the dataset: leave-one-night-out first, then a final fit on every night.
/// Training needs Create ML, which exists on iPhone but not in the simulator.
enum StageTrainer {
    enum TrainingError: LocalizedError, Equatable {
        case unavailable
        case notEnoughData(String)
        case emptyFold

        var errorDescription: String? {
            switch self {
            case .unavailable: "Training needs an iPhone; the simulator has no Create ML."
            case .notEnoughData(let reason): reason
            case .emptyFold: "A held-out night left no training rows."
            }
        }
    }

    #if canImport(CreateML)
    static let isAvailable = true
    #else
    static let isAvailable = false
    #endif

    static func modelURL(for kind: StageModelKind, in directory: URL) -> URL { directory.appendingPathComponent("\(kind.rawValue).mlmodelc") }
    /// The editable model spec, kept beside the compiled one so it can be shared with the analysis container.
    static func specURL(for kind: StageModelKind, in directory: URL) -> URL { directory.appendingPathComponent("\(kind.rawValue).mlmodel") }
    static func cardURL(for kind: StageModelKind, in directory: URL) -> URL { directory.appendingPathComponent("\(kind.rawValue).card.json") }

    static func train(dataset: StageDataset, kind: StageModelKind, into directory: URL,
                      progress: @escaping @Sendable (Double) -> Void,
                      status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> StageTrainingResult {
        guard isAvailable else { throw TrainingError.unavailable }
        if let shortfall = dataset.shortfall { throw TrainingError.notEnoughData(shortfall) }
        // Awaiting a detached task does not make it a child: cancel it explicitly when the caller is cancelled,
        // and the fits check for cancellation between folds and before installing anything.
        let work = Task.detached(priority: .userInitiated) {
            try fitAndEvaluate(dataset: dataset, kind: kind, directory: directory, progress: progress, status: status)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Evaluation and the final fit

    private static func fitAndEvaluate(dataset: StageDataset, kind: StageModelKind, directory: URL,
                                       progress: @escaping @Sendable (Double) -> Void,
                                       status: @escaping @Sendable (String) -> Void) throws -> StageTrainingResult {
        let columns = dataset.contract.columns
        let folds = dataset.leaveOneNightOut()
        guard folds.allSatisfy({ !$0.training.isEmpty }) else { throw TrainingError.emptyFold }
        // A classifier cannot be fitted on one class; with few nights, holding one out can leave exactly that.
        if let fold = folds.first(where: { Set($0.training.map(\.label)).count < 2 }) {
            throw TrainingError.notEnoughData("Holding out \(fold.heldOut.enteredBed.formatted(.dateTime.month(.abbreviated).day())) leaves a single stage to learn from; more Watch nights are needed.")
        }
        // A 200-tree Create ML forest takes about two minutes a fold on an iPhone; the folds run one after
        // another (see `concurrentFolds`) and results are collected in fold order.
        let foldBlocks = try foldPredictions(folds, columns: columns, kind: kind, progress: progress, status: status)
        var perNight: [StageScore?] = [], rulesPerNight: [StageScore?] = [], challengerPerNight: [StageScore?] = []
        var pooledBlocks: [StageDataset.Block] = [], pooledRules: [StageDataset.Block] = [], pooledChallenger: [StageDataset.Block] = []
        var pooledWatch: [StageDataset.Block] = []
        for (fold, blocks) in zip(folds, foldBlocks) {
            // The rules and the challenger are scored on the same labelled epochs only.
            let labelled = Set(fold.heldOut.rows.map(\.start))
            let rules = fold.heldOut.rules.filter { labelled.contains($0.start) }
            let challenger = fold.heldOut.challenger.filter { labelled.contains($0.start) }
            perNight.append(StageScore.score(blocks, reference: fold.heldOut.watch))
            rulesPerNight.append(StageScore.score(rules, reference: fold.heldOut.watch))
            challengerPerNight.append(StageScore.score(challenger, reference: fold.heldOut.watch))
            pooledBlocks += blocks
            pooledRules += rules
            pooledChallenger += challenger
            pooledWatch += fold.heldOut.watch
        }
        let report = StageTrainingReport(
            kind: kind, contract: dataset.contract, nights: dataset.nights.count, epochs: dataset.labeledEpochs,
            pooled: StageScore.score(pooledBlocks, reference: pooledWatch),
            rules: StageScore.score(pooledRules, reference: pooledWatch),
            challenger: pooledChallenger.isEmpty ? nil : StageScore.score(pooledChallenger, reference: pooledWatch),
            perNight: perNight, rulesPerNight: rulesPerNight, challengerPerNight: challengerPerNight)

        // Final fit on every night, installed under the kind's fixed name. The spec is moved into place last,
        // so a failure anywhere leaves the previous model, card and spec consistent with each other.
        try Task.checkCancellation()
        Log.general.notice("Stage trainer: \(kind.rawValue, privacy: .public) final fit on \(dataset.allRows.count) rows")
        status("final fit on \(dataset.allRows.count) rows")
        let rows = dataset.allRows
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let (compiled, spec) = try compile(rows: StageDataset.oversampled(rows), columns: columns, kind: kind, keepSpec: true)
        defer { if let spec { try? fileManager.removeItem(at: spec) } }
        try Task.checkCancellation()
        let modelURL = modelURL(for: kind, in: directory)
        if fileManager.fileExists(atPath: modelURL.path) { try fileManager.removeItem(at: modelURL) }
        try fileManager.moveItem(at: compiled, to: modelURL)
        let classifier = try CoreMLStageClassifier(contentsOf: modelURL, columns: columns)
        let bedTimes = dataset.nights.map(\.enteredBed)
        let card = try card(report: report, rows: rows, classifier: classifier, columns: columns,
                            nightSpan: bedTimes.min().flatMap { first in bedTimes.max().map { (first, $0) } })
        let cardURL = cardURL(for: kind, in: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CardDocument(card)).write(to: cardURL, options: .atomic)
        if let spec {
            let specURL = specURL(for: kind, in: directory)
            try? fileManager.removeItem(at: specURL)
            try fileManager.moveItem(at: spec, to: specURL)
        }
        progress(1)
        return StageTrainingResult(report: report, card: card, modelURL: modelURL, cardURL: cardURL)
    }

    /// Measured on an iPhone 15 Pro: four concurrent Create ML forest fits never finished within an hour,
    /// while one at a time takes about two minutes each, so folds run sequentially.
    static let concurrentFolds = 1

    /// Each fold's held-out predictions, fitted `concurrentFolds` at a time on a concurrent queue.
    private static func foldPredictions(_ folds: [(heldOut: StageDataset.Night, training: [StageDataset.LabeledRow])], columns: [String],
                                        kind: StageModelKind, progress: @escaping @Sendable (Double) -> Void,
                                        status: @escaping @Sendable (String) -> Void) throws -> [[StageDataset.Block]] {
        let results = Locked<[Int: Result<[StageDataset.Block], Error>]>([:])
        let done = Locked(0)
        let queue = DispatchQueue(label: "stage-trainer-folds", attributes: .concurrent)
        let limit = DispatchSemaphore(value: concurrentFolds)
        let group = DispatchGroup()
        for (index, fold) in folds.enumerated() {
            limit.wait()
            group.enter()
            queue.async {
                defer { limit.signal(); group.leave() }
                let started = Date()
                let result = Result { () throws -> [StageDataset.Block] in
                    try Task.checkCancellation()
                    let (compiled, _) = try compile(rows: StageDataset.oversampled(fold.training), columns: columns, kind: kind)
                    // Core ML may map the compiled files lazily, so the directory outlives the predictions.
                    defer { try? FileManager.default.removeItem(at: compiled) }
                    let classifier = try CoreMLStageClassifier(contentsOf: compiled, columns: columns)
                    return try StageDataset.blocks(fold.heldOut.rows, classifier: classifier)
                }
                Log.general.notice("Stage trainer: \(kind.rawValue, privacy: .public) fold \(index + 1)/\(folds.count) fitted in \(Int(Date().timeIntervalSince(started))) s")
                results.with { $0[index] = result }
                let finished = done.with { $0 += 1; return $0 }
                progress(Double(finished) / Double(folds.count + 1))
                status("fold \(finished) of \(folds.count) fitted in \(Int(Date().timeIntervalSince(started))) s")
            }
        }
        group.wait()
        return try folds.indices.map { index in
            guard let result = results.with({ $0[index] }) else { throw TrainingError.emptyFold }
            return try result.get()
        }
    }

    /// A lock around a value, for the fold workers.
    private final class Locked<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()
        init(_ value: Value) { self.value = value }
        func with<T>(_ body: (inout Value) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&value)
        }
    }

    /// The card a personal model is loaded with: the eligibility numbers and test vectors the final model must reproduce.
    static func card(report: StageTrainingReport, rows: [StageDataset.LabeledRow], classifier: any SleepStageClassifying,
                     columns: [String], nightSpan: (first: Date, last: Date)? = nil) throws -> StageChallenger.Card {
        let stride = max(1, rows.count / 12)
        let vectors = try Swift.stride(from: 0, to: rows.count, by: stride).prefix(12).map { index in
            StageChallenger.Card.TestVector(inputs: rows[index].values, expected: try classifier.predict(rows[index].values).classLabel)
        }
        let trainedAt = Date()
        let stamp = trainedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        return StageChallenger.Card(
            version: "personal-\(report.kind.rawValue)-\(stamp)",
            testVectors: vectors,
            model: report.kind.rawValue,
            metrics: .init(lono: report.evaluation(report.pooled), rules: report.evaluation(report.rules),
                           challenger: report.challenger.map(report.evaluation), nightsWon: report.nightsWon, wonPerNight: report.wonPerNight),
            training: .init(dataset: "This iPhone's nights, Apple Watch stages as labels", doi: nil, license: nil, subjects: report.nights,
                            firstNight: nightSpan?.first, lastNight: nightSpan?.last),
            limitations: "Trained on one person's pod nights against their Apple Watch, which is itself an estimate. Experimental, not a medical device.",
            featureContract: columns,
            hyperparameters: report.kind.hyperparameters,
            trainedAt: trainedAt)
    }

    /// The on-disk form of a card, written with the keys `Card` decodes.
    struct CardDocument: Encodable {
        let version: String
        let model: String
        let metrics: [String: StageChallenger.Card.Metrics]
        let training: StageChallenger.Card.Training?
        let limitations: String?
        let featureContract: [String]?
        let hyperparameters: [String: Double]?
        let trainedAt: Date?
        let testVectors: [StageChallenger.Card.TestVector]

        init(_ card: StageChallenger.Card) {
            version = card.version
            model = card.model
            metrics = card.metrics.map { [card.model: $0] } ?? [:]
            training = card.training
            limitations = card.limitations
            featureContract = card.featureContract
            hyperparameters = card.hyperparameters
            trainedAt = card.trainedAt
            testVectors = card.testVectors
        }
    }

    // MARK: Create ML

    #if canImport(CreateML)
    /// Trains and compiles. The compiled directory is returned; the `.mlmodel` spec is deleted unless `keepSpec`,
    /// in which case its temporary URL is returned too for the caller to move into place once the install is done.
    private static func compile(rows: [StageDataset.LabeledRow], columns: [String], kind: StageModelKind, keepSpec: Bool = false) throws -> (URL, URL?) {
        var frame = DataFrame()
        for column in columns {
            frame.append(column: Column(name: column, contents: rows.map { $0.values[column] ?? 0 }))
        }
        frame.append(column: Column(name: "stage", contents: rows.map { Int(StageDataset.classIndex($0.label)) }))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(kind.rawValue)-\(UUID().uuidString).mlmodel")
        switch kind {
        case .logistic:
            let parameters = MLLogisticRegressionClassifier.ModelParameters(
                validation: .none, maxIterations: Int(kind.hyperparameters["maxIterations"] ?? 200),
                l2Penalty: kind.hyperparameters["l2Penalty"] ?? 0.01)
            let model = try MLLogisticRegressionClassifier(trainingData: frame, targetColumn: "stage", parameters: parameters)
            try model.write(to: scratch)
        case .forest:
            let parameters = MLRandomForestClassifier.ModelParameters(
                validation: .none, maxDepth: Int(kind.hyperparameters["maxDepth"] ?? 4),
                maxIterations: Int(kind.hyperparameters["trees"] ?? 200), randomSeed: 42)
            let model = try MLRandomForestClassifier(trainingData: frame, targetColumn: "stage", parameters: parameters)
            try model.write(to: scratch)
        }
        defer { if !keepSpec { try? FileManager.default.removeItem(at: scratch) } }
        let compiled = try MLModel.compileModel(at: scratch)
        return (compiled, keepSpec ? scratch : nil)
    }
    #else
    private static func compile(rows: [StageDataset.LabeledRow], columns: [String], kind: StageModelKind, keepSpec: Bool = false) throws -> (URL, URL?) {
        throw TrainingError.unavailable
    }
    #endif
}
