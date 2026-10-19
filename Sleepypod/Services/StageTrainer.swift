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
    /// Pinned to sleepypod-core's research script (feat2.py) so the container run and the device fit match.
    var hyperparameters: [String: Double] {
        switch self {
        case .logistic: ["maxIterations": 200, "l2Penalty": 0.01]
        case .forest: ["trees": 200, "maxDepth": 4]
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
    var nightsWon: Int {
        perNight.indices.filter { index in
            guard let mine = perNight[index]?.kappa else { return false }
            let rulesKappa = rulesPerNight[index]?.kappa ?? -1
            let challengerKappa = challengerPerNight[index]?.kappa ?? -1
            return mine > rulesKappa && mine > challengerKappa
        }.count
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
    static func cardURL(for kind: StageModelKind, in directory: URL) -> URL { directory.appendingPathComponent("\(kind.rawValue).card.json") }

    static func train(dataset: StageDataset, kind: StageModelKind, into directory: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> StageTrainingResult {
        guard isAvailable else { throw TrainingError.unavailable }
        if let shortfall = dataset.shortfall { throw TrainingError.notEnoughData(shortfall) }
        return try await Task.detached(priority: .userInitiated) {
            try fitAndEvaluate(dataset: dataset, kind: kind, directory: directory, progress: progress)
        }.value
    }

    // MARK: Evaluation and the final fit

    private static func fitAndEvaluate(dataset: StageDataset, kind: StageModelKind, directory: URL,
                                       progress: @Sendable (Double) -> Void) throws -> StageTrainingResult {
        let columns = dataset.contract.columns
        let folds = dataset.leaveOneNightOut()
        var perNight: [StageScore?] = [], rulesPerNight: [StageScore?] = [], challengerPerNight: [StageScore?] = []
        var pooledBlocks: [StageDataset.Block] = [], pooledRules: [StageDataset.Block] = [], pooledChallenger: [StageDataset.Block] = []
        var pooledWatch: [StageDataset.Block] = []
        for (index, fold) in folds.enumerated() {
            try Task.checkCancellation()
            guard !fold.training.isEmpty else { throw TrainingError.emptyFold }
            let classifier = try fit(rows: StageDataset.oversampled(fold.training), columns: columns, kind: kind)
            let blocks = try StageDataset.blocks(fold.heldOut.rows, classifier: classifier)
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
            progress(Double(index + 1) / Double(folds.count + 1))
        }
        let report = StageTrainingReport(
            kind: kind, contract: dataset.contract, nights: dataset.nights.count, epochs: dataset.labeledEpochs,
            pooled: StageScore.score(pooledBlocks, reference: pooledWatch),
            rules: StageScore.score(pooledRules, reference: pooledWatch),
            challenger: pooledChallenger.isEmpty ? nil : StageScore.score(pooledChallenger, reference: pooledWatch),
            perNight: perNight, rulesPerNight: rulesPerNight, challengerPerNight: challengerPerNight)

        // Final fit on every night, installed under the kind's fixed name.
        let rows = dataset.allRows
        let compiled = try compile(rows: StageDataset.oversampled(rows), columns: columns, kind: kind)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelURL = modelURL(for: kind, in: directory)
        if fileManager.fileExists(atPath: modelURL.path) { try fileManager.removeItem(at: modelURL) }
        try fileManager.moveItem(at: compiled, to: modelURL)
        let classifier = try CoreMLStageClassifier(contentsOf: modelURL, columns: columns)
        let card = try card(report: report, rows: rows, classifier: classifier, columns: columns)
        let cardURL = cardURL(for: kind, in: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CardDocument(card)).write(to: cardURL, options: .atomic)
        progress(1)
        return StageTrainingResult(report: report, card: card, modelURL: modelURL, cardURL: cardURL)
    }

    /// The card a personal model is loaded with: the eligibility numbers and test vectors the final model must reproduce.
    static func card(report: StageTrainingReport, rows: [StageDataset.LabeledRow], classifier: any SleepStageClassifying,
                     columns: [String]) throws -> StageChallenger.Card {
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
                           challenger: report.challenger.map(report.evaluation), nightsWon: report.nightsWon),
            training: .init(dataset: "This iPhone's nights, Apple Watch stages as labels", doi: nil, license: nil, subjects: report.nights),
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

    /// A classifier fitted on rows, compiled to a temporary directory and loaded through Core ML, so held-out
    /// predictions go through exactly the runtime path.
    private static func fit(rows: [StageDataset.LabeledRow], columns: [String], kind: StageModelKind) throws -> CoreMLStageClassifier {
        let compiled = try compile(rows: rows, columns: columns, kind: kind)
        defer { try? FileManager.default.removeItem(at: compiled) }
        return try CoreMLStageClassifier(contentsOf: compiled, columns: columns)
    }

    #if canImport(CreateML)
    private static func compile(rows: [StageDataset.LabeledRow], columns: [String], kind: StageModelKind) throws -> URL {
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
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try MLModel.compileModel(at: scratch)
    }
    #else
    private static func compile(rows: [StageDataset.LabeledRow], columns: [String], kind: StageModelKind) throws -> URL {
        throw TrainingError.unavailable
    }
    #endif
}
