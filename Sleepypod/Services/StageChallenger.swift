import CoreML
import Foundation

/// The experimental "challenger" sleep stage model: a Core ML classifier trained off-device on the
/// PhysioNet Walch (2019) wrist-wearable set, after ojwalch/sleep_classifiers, and run here on the pod's vitals.
///
/// Feature computation is part of the model's contract and must stay identical to the off-device evaluator:
/// 5-minute epochs from enteredBedAt (a trailing partial epoch is dropped), epochs without a heart-rate
/// sample skipped, per-night z-scores with the population std (0 when the std is 0).
enum StageChallenger {
    static let epochSeconds: TimeInterval = 300
    static let resourceName = "SleepStageChallenger"
    static let cardResourceName = "SleepStageChallenger.card"

    static let acknowledgements = [
        "Sleep stage model trained on 'Motion and heart rate from a wrist-worn wearable and labeled sleep from polysomnography' (Walch, 2019), PhysioNet, ODC-By 1.0, https://doi.org/10.13026/hmhs-py35",
        "Method after ojwalch/sleep_classifiers (MIT)."
    ]

    /// The bundled model's inputs (feature contract A); `values` is the named-column form every classifier takes.
    struct Features: Codable, Sendable, Equatable {
        let hrZ: Double
        let hrStdZ: Double
        let motionZ: Double
        let nightFraction: Double

        static let columns = ["hrZ", "hrStdZ", "motionZ", "nightFraction"]
        var values: [String: Double] { ["hrZ": hrZ, "hrStdZ": hrStdZ, "motionZ": motionZ, "nightFraction": nightFraction] }
    }

    /// One epoch's inputs by column name, so contracts with different columns share the classifier path.
    struct FeatureEpoch: Sendable, Equatable {
        let start: Date
        let values: [String: Double]
    }

    struct Prediction: Sendable, Equatable {
        let classLabel: Int64
        let probabilities: [Int64: Double]
        var stage: SleepAnalyzer.SleepStage? { StageChallenger.stage(for: classLabel) }
    }

    enum ModelError: Error, LocalizedError, Equatable {
        case missingOutput(String)
        case missingInput(String)
        case unknownClass(Int64)

        var errorDescription: String? {
            switch self {
            case .missingOutput(let name): "The model returned no \(name)"
            case .missingInput(let name): "The features have no \(name) column"
            case .unknownClass(let label): "The model returned class \(label), outside 0–3"
            }
        }
    }

    /// The model's class labels: 0 = wake, 1 = light, 2 = deep, 3 = rem.
    static func stage(for classLabel: Int64) -> SleepAnalyzer.SleepStage? {
        switch classLabel {
        case 0: .wake
        case 1: .light
        case 2: .deep
        case 3: .rem
        default: nil
        }
    }

    // MARK: Features

    /// One night's model inputs. Only epochs with at least one heart-rate sample are returned; the rest are gaps.
    static func features(enteredBed: Date, leftBed: Date, vitals: [VitalsRecord], movement: [MovementRecord]) -> [FeatureEpoch] {
        let night = leftBed.timeIntervalSince(enteredBed)
        guard night >= epochSeconds else { return [] }
        let count = Int((night / epochSeconds).rounded(.down))
        let heartRates = vitals.compactMap { record in record.heartRate.map { (date: record.date, value: $0) } }
            .filter { $0.value.isFinite }

        var kept: [(start: Date, hr: Double, hrStd: Double, motion: Double)] = []
        for index in 0..<count {
            let start = enteredBed.addingTimeInterval(Double(index) * epochSeconds)
            let end = start.addingTimeInterval(epochSeconds)
            let samples = heartRates.filter { $0.date >= start && $0.date < end }.map(\.value)
            guard !samples.isEmpty else { continue }
            let hr = mean(samples)
            let hrStd = samples.count < 2 ? 0 : populationStd(samples)
            let motion = movement.filter { $0.date >= start && $0.date < end }.reduce(0.0) { $0 + Double($1.totalMovement) }
            kept.append((start, hr, hrStd, motion))
        }

        let hrZ = zScores(kept.map(\.hr))
        let hrStdZ = zScores(kept.map(\.hrStd))
        let motionZ = zScores(kept.map { log(1 + $0.motion) })
        return kept.indices.map { index in
            FeatureEpoch(start: kept[index].start, values: Features(
                hrZ: hrZ[index], hrStdZ: hrStdZ[index], motionZ: motionZ[index],
                nightFraction: kept[index].start.timeIntervalSince(enteredBed) / night).values)
        }
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func populationStd(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let average = mean(values)
        return sqrt(values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count))
    }

    static func zScores(_ values: [Double]) -> [Double] {
        let average = mean(values)
        let std = populationStd(values)
        return values.map { std == 0 ? 0 : ($0 - average) / std }
    }

    // MARK: Classification

    /// Each kept epoch as a 5-minute block of the predicted stage.
    static func classify(_ epochs: [FeatureEpoch], with classifier: any SleepStageClassifying) throws -> [WatchComparison.StageSample] {
        try epochs.map { epoch in
            let prediction = try classifier.predict(epoch.values)
            guard let stage = prediction.stage else { throw ModelError.unknownClass(prediction.classLabel) }
            return WatchComparison.StageSample(start: epoch.start, end: epoch.start.addingTimeInterval(epochSeconds), stage: stage)
        }
    }

    // MARK: Model card

    struct Card: Decodable, Sendable, Equatable {
        struct TestVector: Codable, Sendable, Equatable {
            let inputs: [String: Double]
            let expected: Int64

            init(inputs: [String: Double], expected: Int64) {
                self.inputs = inputs
                self.expected = expected
            }

            private enum CodingKeys: String, CodingKey { case inputs, input, expected, expectedClass, classLabel }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(inputs, forKey: .inputs)
                try c.encode(expected, forKey: .expected)
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                inputs = try c.decodeIfPresent([String: Double].self, forKey: .inputs) ?? c.decode([String: Double].self, forKey: .input)
                expected = try c.decodeIfPresent(Int64.self, forKey: .expected)
                    ?? c.decodeIfPresent(Int64.self, forKey: .expectedClass)
                    ?? c.decode(Int64.self, forKey: .classLabel)
            }
        }

        /// One evaluation's headline numbers; the card's confusion matrices and per-night rows are left in the file.
        struct Evaluation: Codable, Sendable, Equatable {
            let epochs: Int?
            let kappa: Double?
            let accuracy: Double?
            let nights: Int?
        }
        struct Metrics: Codable, Sendable, Equatable {
            /// Leave-one-subject-out on the training set.
            let loso: Evaluation?
            /// Against Apple Watch stages on the developer's pod nights.
            let pod: Evaluation?
            /// Leave-one-night-out on this phone's nights (personal models).
            let lono: Evaluation?
            /// The rules and the bundled challenger on the same held-out epochs, for the eligibility bar.
            let rules: Evaluation?
            let challenger: Evaluation?
            /// Nights on which the personal model's κ beat both the rules and the challenger.
            let nightsWon: Int?

            init(loso: Evaluation? = nil, pod: Evaluation? = nil, lono: Evaluation? = nil, rules: Evaluation? = nil,
                 challenger: Evaluation? = nil, nightsWon: Int? = nil) {
                self.loso = loso
                self.pod = pod
                self.lono = lono
                self.rules = rules
                self.challenger = challenger
                self.nightsWon = nightsWon
            }
        }
        struct Training: Codable, Sendable, Equatable {
            let dataset: String?
            let doi: String?
            let license: String?
            let subjects: Int?
        }

        let version: String
        let testVectors: [TestVector]
        /// The model kind the card describes ("forest", "logistic").
        var model: String
        /// The card's metrics for the bundled model kind (`model`, e.g. "forest").
        var metrics: Metrics?
        var training: Training?
        var limitations: String?
        /// Ordered input columns; a card without one is the bundled challenger's four-column contract A.
        var featureContract: [String]?
        var hyperparameters: [String: Double]?
        var trainedAt: Date?

        var columns: [String] { featureContract ?? Features.columns }

        init(version: String, testVectors: [TestVector], model: String = "forest", metrics: Metrics? = nil, training: Training? = nil,
             limitations: String? = nil, featureContract: [String]? = nil, hyperparameters: [String: Double]? = nil, trainedAt: Date? = nil) {
            self.version = version
            self.testVectors = testVectors
            self.model = model
            self.metrics = metrics
            self.training = training
            self.limitations = limitations
            self.featureContract = featureContract
            self.hyperparameters = hyperparameters
            self.trainedAt = trainedAt
        }

        private enum CodingKeys: String, CodingKey {
            case version, testVectors, model, metrics, training, limitations, featureContract, hyperparameters, trainedAt
            case testVectorsSnake = "test_vectors"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? c.decode(String.self, forKey: .version) {
                version = text
            } else {
                version = String(try c.decode(Double.self, forKey: .version))
            }
            testVectors = try c.decodeIfPresent([TestVector].self, forKey: .testVectors)
                ?? c.decode([TestVector].self, forKey: .testVectorsSnake)
            let kind = try c.decodeIfPresent(String.self, forKey: .model) ?? "forest"
            model = kind
            metrics = (try? c.decodeIfPresent([String: Metrics].self, forKey: .metrics))?[kind]
            training = try? c.decodeIfPresent(Training.self, forKey: .training)
            limitations = try? c.decodeIfPresent(String.self, forKey: .limitations)
            featureContract = try? c.decodeIfPresent([String].self, forKey: .featureContract)
            hyperparameters = try? c.decodeIfPresent([String: Double].self, forKey: .hyperparameters)
            trainedAt = try? c.decodeIfPresent(Date.self, forKey: .trainedAt)
        }
    }

    /// Indices of the card's test vectors the classifier gets wrong (or cannot run).
    static func failingVectors(_ card: Card, classifier: any SleepStageClassifying) -> [Int] {
        card.testVectors.indices.filter { index in
            (try? classifier.predict(card.testVectors[index].inputs).classLabel) != card.testVectors[index].expected
        }
    }

    // MARK: Loading

    enum Availability: Sendable {
        case ready(any SleepStageClassifying, Card)
        case notBundled
        case failed(String)

        var card: Card? {
            if case .ready(_, let card) = self { return card }
            return nil
        }
        var version: String? { card?.version }
        var classifier: (any SleepStageClassifying)? {
            if case .ready(let classifier, _) = self { return classifier }
            return nil
        }
    }

    static func isBundled(in bundle: Bundle = .main) -> Bool {
        bundle.url(forResource: resourceName, withExtension: "mlmodelc") != nil
    }

    /// Loaded once; a model that disagrees with its own card's test vectors is refused rather than shown.
    @MainActor static let bundled: Availability = load(from: .main)

    static func load(from bundle: Bundle) -> Availability {
        guard let modelURL = bundle.url(forResource: resourceName, withExtension: "mlmodelc") else { return .notBundled }
        guard let cardURL = bundle.url(forResource: cardResourceName, withExtension: "json") else {
            return .failed("\(cardResourceName).json is missing")
        }
        return load(modelURL: modelURL, cardURL: cardURL)
    }

    static let cardDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A compiled model and its card from anywhere on disk: the app bundle, or Application Support for a personal model.
    static func load(modelURL: URL, cardURL: URL) -> Availability {
        do {
            let card = try cardDecoder.decode(Card.self, from: Data(contentsOf: cardURL))
            let classifier = try CoreMLStageClassifier(contentsOf: modelURL, columns: card.columns)
            let failing = failingVectors(card, classifier: classifier)
            guard failing.isEmpty else {
                Log.general.error("Stage challenger failed \(failing.count) of \(card.testVectors.count) card test vectors")
                return .failed("Model fails \(failing.count) of its \(card.testVectors.count) test vectors")
            }
            return .ready(classifier, card)
        } catch {
            Log.general.error("Stage challenger failed to load: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}

/// One epoch in, one stage class out. Core ML in the app, a test double in tests. Inputs are named columns so
/// the bundled challenger and personal models with other feature contracts share one path.
protocol SleepStageClassifying: Sendable {
    func predict(_ features: [String: Double]) throws -> StageChallenger.Prediction
}

/// Runs a compiled stage model through the generic Core ML API, so the app builds without any model and
/// picks one up from the bundle or from disk. MLModel is safe to call from any thread.
final class CoreMLStageClassifier: SleepStageClassifying, @unchecked Sendable {
    private let model: MLModel
    /// The model's input names; a missing column in the features is an error rather than a silent zero.
    let columns: [String]

    init(model: MLModel, columns: [String] = StageChallenger.Features.columns) {
        self.model = model
        self.columns = columns
    }

    convenience init(contentsOf url: URL, columns: [String] = StageChallenger.Features.columns) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        self.init(model: try MLModel(contentsOf: url, configuration: configuration), columns: columns)
    }

    func predict(_ features: [String: Double]) throws -> StageChallenger.Prediction {
        var dictionary: [String: MLFeatureValue] = [:]
        for column in columns {
            guard let value = features[column] else { throw StageChallenger.ModelError.missingInput(column) }
            dictionary[column] = MLFeatureValue(double: value)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: dictionary)
        let output = try model.prediction(from: input)
        // coremltools names the outputs classLabel/classProbability; Create ML names them after the target
        // column (stage/stageProbability). Pick them by type so both load through the same wrapper.
        let outputs = model.modelDescription.outputDescriptionsByName
        let labelName = outputs.first { $0.key == "classLabel" }?.key ?? outputs.first { $0.value.type == .int64 }?.key ?? "classLabel"
        let probabilityName = outputs.first { $0.key == "classProbability" }?.key ?? outputs.first { $0.value.type == .dictionary }?.key ?? "classProbability"
        guard let label = output.featureValue(for: labelName), label.type == .int64 else {
            throw StageChallenger.ModelError.missingOutput(labelName)
        }
        var probabilities: [Int64: Double] = [:]
        for (key, value) in output.featureValue(for: probabilityName)?.dictionaryValue ?? [:] {
            if let key = key as? Int64 ?? (key as? NSNumber)?.int64Value { probabilities[key] = value.doubleValue }
        }
        // The converted random forest sums its trees' votes (totals of 100) rather than averaging them.
        let total = probabilities.values.reduce(0, +)
        if total > 0 { probabilities = probabilities.mapValues { $0 / total } }
        return StageChallenger.Prediction(classLabel: label.int64Value, probabilities: probabilities)
    }
}
