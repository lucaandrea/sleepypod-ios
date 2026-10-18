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

    struct Features: Codable, Sendable, Equatable {
        let hrZ: Double
        let hrStdZ: Double
        let motionZ: Double
        let nightFraction: Double
    }

    struct FeatureEpoch: Sendable, Equatable {
        let start: Date
        let features: Features
    }

    struct Prediction: Sendable, Equatable {
        let classLabel: Int64
        let probabilities: [Int64: Double]
        var stage: SleepAnalyzer.SleepStage? { StageChallenger.stage(for: classLabel) }
    }

    enum ModelError: Error, LocalizedError, Equatable {
        case missingOutput(String)
        case unknownClass(Int64)

        var errorDescription: String? {
            switch self {
            case .missingOutput(let name): "The model returned no \(name)"
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
            FeatureEpoch(start: kept[index].start, features: Features(
                hrZ: hrZ[index], hrStdZ: hrStdZ[index], motionZ: motionZ[index],
                nightFraction: kept[index].start.timeIntervalSince(enteredBed) / night))
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
            let prediction = try classifier.predict(epoch.features)
            guard let stage = prediction.stage else { throw ModelError.unknownClass(prediction.classLabel) }
            return WatchComparison.StageSample(start: epoch.start, end: epoch.start.addingTimeInterval(epochSeconds), stage: stage)
        }
    }

    // MARK: Model card

    struct Card: Decodable, Sendable, Equatable {
        struct TestVector: Decodable, Sendable, Equatable {
            let inputs: Features
            let expected: Int64

            init(inputs: Features, expected: Int64) {
                self.inputs = inputs
                self.expected = expected
            }

            private enum CodingKeys: String, CodingKey { case inputs, input, expected, expectedClass, classLabel }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                inputs = try c.decodeIfPresent(Features.self, forKey: .inputs) ?? c.decode(Features.self, forKey: .input)
                expected = try c.decodeIfPresent(Int64.self, forKey: .expected)
                    ?? c.decodeIfPresent(Int64.self, forKey: .expectedClass)
                    ?? c.decode(Int64.self, forKey: .classLabel)
            }
        }

        /// One evaluation's headline numbers; the card's confusion matrices and per-night rows are left in the file.
        struct Evaluation: Decodable, Sendable, Equatable {
            let epochs: Int?
            let kappa: Double?
            let accuracy: Double?
            let nights: Int?
        }
        struct Metrics: Decodable, Sendable, Equatable {
            /// Leave-one-subject-out on the training set.
            let loso: Evaluation?
            /// Against Apple Watch stages on the developer's pod nights.
            let pod: Evaluation?
        }
        struct Training: Decodable, Sendable, Equatable {
            let dataset: String?
            let doi: String?
            let license: String?
            let subjects: Int?
        }

        let version: String
        let testVectors: [TestVector]
        /// The card's metrics for the bundled model kind (`model`, e.g. "forest").
        var metrics: Metrics?
        var training: Training?
        var limitations: String?

        init(version: String, testVectors: [TestVector], metrics: Metrics? = nil, training: Training? = nil, limitations: String? = nil) {
            self.version = version
            self.testVectors = testVectors
            self.metrics = metrics
            self.training = training
            self.limitations = limitations
        }

        private enum CodingKeys: String, CodingKey {
            case version, testVectors, model, metrics, training, limitations
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
            metrics = (try? c.decodeIfPresent([String: Metrics].self, forKey: .metrics))?[kind]
            training = try? c.decodeIfPresent(Training.self, forKey: .training)
            limitations = try? c.decodeIfPresent(String.self, forKey: .limitations)
        }
    }

    /// Indices of the card's test vectors the classifier gets wrong (or cannot run).
    static func failingVectors(_ card: Card, classifier: any SleepStageClassifying) -> [Int] {
        card.testVectors.indices.filter { index in
            (try? classifier.predict(card.testVectors[index].inputs).classLabel) != card.testVectors[index].expected
        }
    }

    // MARK: Loading

    enum Availability {
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
        do {
            let card = try JSONDecoder().decode(Card.self, from: Data(contentsOf: cardURL))
            let classifier = try CoreMLStageClassifier(contentsOf: modelURL)
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

/// One epoch in, one stage class out. Core ML in the app, a test double in tests.
protocol SleepStageClassifying {
    func predict(_ features: StageChallenger.Features) throws -> StageChallenger.Prediction
}

/// Runs `SleepStageChallenger.mlmodel` through the generic Core ML API, so the app builds without the model
/// and picks it up once the compiled resource is in the bundle.
final class CoreMLStageClassifier: SleepStageClassifying {
    private let model: MLModel

    init(model: MLModel) {
        self.model = model
    }

    convenience init(contentsOf url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        self.init(model: try MLModel(contentsOf: url, configuration: configuration))
    }

    func predict(_ features: StageChallenger.Features) throws -> StageChallenger.Prediction {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "hrZ": MLFeatureValue(double: features.hrZ),
            "hrStdZ": MLFeatureValue(double: features.hrStdZ),
            "motionZ": MLFeatureValue(double: features.motionZ),
            "nightFraction": MLFeatureValue(double: features.nightFraction)
        ])
        let output = try model.prediction(from: input)
        guard let label = output.featureValue(for: "classLabel"), label.type == .int64 else {
            throw StageChallenger.ModelError.missingOutput("classLabel")
        }
        var probabilities: [Int64: Double] = [:]
        for (key, value) in output.featureValue(for: "classProbability")?.dictionaryValue ?? [:] {
            if let key = key as? Int64 ?? (key as? NSNumber)?.int64Value { probabilities[key] = value.doubleValue }
        }
        // The converted random forest sums its trees' votes (totals of 100) rather than averaging them.
        let total = probabilities.values.reduce(0, +)
        if total > 0 { probabilities = probabilities.mapValues { $0 / total } }
        return StageChallenger.Prediction(classLabel: label.int64Value, probabilities: probabilities)
    }
}
