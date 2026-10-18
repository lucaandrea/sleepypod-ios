import Testing
import Foundation
@testable import Sleepypod

/// Stands in for the Core ML model: a fixed rule from features to class label.
private struct RuleClassifier: SleepStageClassifying {
    let rule: @Sendable (StageChallenger.Features) -> Int64
    func predict(_ features: StageChallenger.Features) throws -> StageChallenger.Prediction {
        let label = rule(features)
        return StageChallenger.Prediction(classLabel: label, probabilities: [label: 1])
    }
}

@Suite("Stage challenger model")
@MainActor
struct StageChallengerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func vital(_ second: TimeInterval, _ hr: Double?) -> VitalsRecord {
        VitalsRecord(id: Int(second), heartRate: hr, hrv: 40, date: t0.addingTimeInterval(second))
    }
    private func move(_ second: TimeInterval, _ amount: Int) -> MovementRecord {
        MovementRecord(id: Int(second), totalMovement: amount, date: t0.addingTimeInterval(second))
    }

    // MARK: Features

    /// 21 minutes in bed: four whole epochs, the trailing minute dropped. Epoch 1 has no heart rate and is skipped.
    @Test func featuresFollowTheContract() throws {
        let vitals = [vital(0, 60), vital(60, 62), vital(400, nil), vital(600, 70),
                      vital(900, 64), vital(960, 64), vital(1020, 64), vital(1200, 100)]
        let movement = [move(30, 10), move(290, 5), move(350, 100), move(1000, 3)]
        let epochs = StageChallenger.features(enteredBed: t0, leftBed: t0.addingTimeInterval(1260), vitals: vitals, movement: movement)

        #expect(epochs.map { $0.start.timeIntervalSince(t0) } == [0, 600, 900])
        // hr [61, 70, 64]: mean 65, population std √14.
        let hrStd = sqrt(14.0)
        // hrStd [1, 0, 0]: mean 1/3, population std √2/3.
        // ln(1 + motion) [ln 16, 0, ln 4]: mean 2 ln 2, population std 2 ln 2 · √(2/3).
        let expected: [(hrZ: Double, hrStdZ: Double, motionZ: Double, fraction: Double)] = [
            (-4 / hrStd, sqrt(2), sqrt(1.5), 0),
            (5 / hrStd, -1 / sqrt(2), -sqrt(1.5), 600.0 / 1260),
            (-1 / hrStd, -1 / sqrt(2), 0, 900.0 / 1260)
        ]
        for (epoch, want) in zip(epochs, expected) {
            #expect(abs(epoch.features.hrZ - want.hrZ) < 1e-9)
            #expect(abs(epoch.features.hrStdZ - want.hrStdZ) < 1e-9)
            #expect(abs(epoch.features.motionZ - want.motionZ) < 1e-9)
            #expect(abs(epoch.features.nightFraction - want.fraction) < 1e-12)
        }
    }

    @Test func constantFeaturesScoreZeroAndShortNightsHaveNoEpochs() {
        let vitals = (0..<6).map { vital(Double($0) * 300 + 10, 58) }
        let epochs = StageChallenger.features(enteredBed: t0, leftBed: t0.addingTimeInterval(1800), vitals: vitals, movement: [])
        #expect(epochs.count == 6)
        #expect(epochs.allSatisfy { $0.features.hrZ == 0 && $0.features.hrStdZ == 0 && $0.features.motionZ == 0 })
        #expect(epochs.allSatisfy { (0..<1).contains($0.features.nightFraction) })
        #expect(StageChallenger.features(enteredBed: t0, leftBed: t0.addingTimeInterval(299), vitals: vitals, movement: []).isEmpty)
    }

    // MARK: Wrapper with a test double

    @Test func classifyMapsLabelsToFiveMinuteBlocks() throws {
        let epochs = [0, 300, 900].map { StageChallenger.FeatureEpoch(start: t0.addingTimeInterval($0), features: .init(hrZ: $0 / 300, hrStdZ: 0, motionZ: 0, nightFraction: 0)) }
        let blocks = try StageChallenger.classify(epochs, with: RuleClassifier { Int64($0.hrZ) })
        #expect(blocks.map(\.stage) == [.wake, .light, .rem])
        #expect(blocks.map { $0.end.timeIntervalSince($0.start) } == [300, 300, 300])
        #expect(blocks[2].start == t0.addingTimeInterval(900))
        #expect(throws: StageChallenger.ModelError.unknownClass(7)) {
            try StageChallenger.classify(epochs, with: RuleClassifier { _ in 7 })
        }
    }

    @Test func cardVectorsAreCheckedThroughTheClassifier() throws {
        let json = """
        {"version": "0.1", "model": "forest",
         "metrics": {"forest": {"loso": {"kappa": 0.3, "accuracy": 0.5}, "pod": {"kappa": 0.1, "nights": 2, "confusion": [[1]]}}},
         "training": {"subjects": 4},
         "testVectors": [{"input": {"hrZ": 2, "hrStdZ": 0, "motionZ": 0, "nightFraction": 0.1}, "classLabel": 2},
                         {"input": {"hrZ": 3, "hrStdZ": 0, "motionZ": 0, "nightFraction": 0.9}, "classLabel": 1}]}
        """
        let card = try JSONDecoder().decode(StageChallenger.Card.self, from: Data(json.utf8))
        #expect(card.version == "0.1")
        #expect(card.metrics?.loso?.kappa == 0.3)
        #expect(card.metrics?.pod?.nights == 2)
        #expect(card.training?.subjects == 4)
        #expect(StageChallenger.failingVectors(card, classifier: RuleClassifier { Int64($0.hrZ) }) == [1])
        #expect(StageChallenger.failingVectors(card, classifier: RuleClassifier { $0.nightFraction < 0.5 ? 2 : 1 }).isEmpty)
    }

    // MARK: The bundled model

    @Test func bundledModelLoadsWithItsCard() throws {
        let availability = StageChallenger.load(from: .main)
        let card = try #require(availability.card, "SleepStageChallenger.mlmodel and its card must be bundled and pass the card's vectors")
        #expect(card.version == "1.0.0")
        #expect(card.testVectors.count >= 1)
        #expect(card.metrics?.loso?.kappa != nil)
        #expect(card.metrics?.pod?.kappa != nil)
        #expect(card.training?.subjects != nil)
    }

    /// Every test vector in the shipped card, run through the real compiled model with Core ML.
    @Test func bundledModelMatchesEveryCardTestVector() throws {
        let modelURL = try #require(Bundle.main.url(forResource: StageChallenger.resourceName, withExtension: "mlmodelc"))
        let cardURL = try #require(Bundle.main.url(forResource: StageChallenger.cardResourceName, withExtension: "json"))
        let card = try JSONDecoder().decode(StageChallenger.Card.self, from: Data(contentsOf: cardURL))
        let model = try CoreMLStageClassifier(contentsOf: modelURL)
        #expect(!card.testVectors.isEmpty)
        for (index, vector) in card.testVectors.enumerated() {
            let prediction = try model.predict(vector.inputs)
            #expect(prediction.classLabel == vector.expected, "test vector \(index)")
            #expect(prediction.stage != nil)
            let total = prediction.probabilities.values.reduce(0, +)
            #expect(abs(total - 1) < 1e-9, "test vector \(index) probabilities sum to \(total)")
            #expect(prediction.probabilities.max { $0.value < $1.value }?.key == vector.expected, "test vector \(index) most probable class")
        }
    }
}
