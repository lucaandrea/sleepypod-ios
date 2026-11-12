import Foundation

/// Conditional water research is separate from comfort-feedback learning and hardware control.
struct TargetResponseResearch: Codable, Sendable {
    struct Evidence: Codable, Sendable {
        struct Exclusion: Codable, Sendable { let date: String; let count: Int; let reason: String }
        let apiVersion: Int
        let policy: String
        let generatedAt: Double
        let side: Side
        let attribution: String
        let status: String
        let reviewedNights: Int
        let responseNights: Int
        let coolingWindows: Int
        let warmingWindows: Int
        let requiredNights: Int
        let datasetHash: String
        let modelAvailable: Bool
        let activationAvailable: Bool
        let exclusions: [Exclusion]
        let exclusionsTruncated: Bool
        let reason: String
    }
    struct Model: Codable, Sendable {
        struct Horizon: Codable, Sendable, Identifiable {
            struct Validation: Codable, Sendable {
                let modelMaeF: Double
                let persistenceMaeF: Double
                let simpleMaeF: Double
                let trendMaeF: Double
                let intervalCoverage: Double
                let supportedFraction: Double
                let passes: Bool
                var bestBaselineF: Double { min(persistenceMaeF, simpleMaeF, trendMaeF) }
                var meetsPolicy: Bool {
                    supportedFraction >= 0.9 && intervalCoverage >= 0.8
                        && modelMaeF <= bestBaselineF * 0.9 && bestBaselineF - modelMaeF >= 0.1
                }
            }
            let minutes: Int
            let errorBandF: Double
            let validation: Validation
            var id: Int { minutes }
        }
        let id: String
        let current: Bool
        let version: String
        let purpose: String
        let mode: String
        let attribution: String
        let side: Side
        let createdAt: Double
        let sourceLastAt: Double
        let datasetHash: String
        let configuration: String
        let trainingDates: [String]
        let calibrationDates: [String]
        let validationDates: [String]
        let horizons: [Horizon]
        var passed: Bool { horizons.count == 2 && horizons.allSatisfy { $0.validation.passes && $0.validation.meetsPolicy } }
    }
    let apiVersion: Int
    let side: Side
    let generatedAt: Double
    let completeNights: Int
    let requiredNights: Int
    let datasetHash: String
    let canTrain: Bool
    let activationAvailable: Bool
    let reason: String
    let evidence: Evidence
    let model: Model?

    var state: String {
        guard evidence.status == "read" else { return "Check source readings" }
        if let model { return !model.current ? "Needs recheck" : model.passed ? "Research preview" : "Not reliable yet" }
        return canTrain ? "Ready to evaluate" : "Collecting evidence"
    }
    var canEvaluate: Bool { canTrain && !(model?.current == true && model?.datasetHash == datasetHash) }
    var canPreview: Bool { evidence.status == "read" && model?.current == true && model?.passed == true }

    func validate(side expectedSide: Side, now: Date) throws {
        let validCounts = [completeNights, evidence.reviewedNights, evidence.responseNights, evidence.coolingWindows, evidence.warmingWindows].allSatisfy { $0 >= 0 }
        guard apiVersion == 1, side == expectedSide, Self.fresh(generatedAt, now: now, seconds: 300),
              requiredNights == 20, Self.digest(datasetHash), !activationAvailable, validCounts,
              evidence.apiVersion == 1, evidence.policy == "acknowledged-small-step-v1", evidence.side == side,
              evidence.generatedAt == generatedAt, evidence.attribution == "physical_zone_only",
              ["read", "partial", "unavailable"].contains(evidence.status), evidence.datasetHash == datasetHash,
              evidence.responseNights == completeNights, evidence.responseNights <= evidence.reviewedNights,
              evidence.requiredNights == 20, !evidence.modelAvailable, !evidence.activationAvailable,
              evidence.exclusions.count <= 300, evidence.exclusions.allSatisfy({ $0.count >= 0 }),
              !canTrain || (evidence.status == "read" && completeNights >= requiredNights) else { throw Self.invalid }
        guard let model else { return }
        try model.validate(side: side, now: now)
        guard !model.current || evidence.status == "read" else { throw Self.invalid }
    }

    static func fresh(_ milliseconds: Double, now: Date, seconds: Double) -> Bool {
        guard milliseconds.isFinite, milliseconds > 0, milliseconds.rounded() == milliseconds else { return false }
        let age = now.timeIntervalSince1970 - milliseconds / 1000
        return age >= 0 && age < seconds
    }
    static func digest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static var invalid: APIError { .serverError(message: "The response evidence is invalid, expired or belongs to another side. Check the Pod again.") }
}

private extension TargetResponseResearch.Model {
    func validate(side expectedSide: Side, now: Date) throws {
        let dates = trainingDates + calibrationDates + validationDates
        guard version == "target-response-ridge-v1", purpose == "observed-water-response", mode == "research_preview",
              attribution == "physical_zone_only", side == expectedSide,
              [id, datasetHash, configuration].allSatisfy(TargetResponseResearch.digest),
              createdAt.isFinite, sourceLastAt.isFinite, sourceLastAt > 0, sourceLastAt < createdAt,
              createdAt.rounded() == createdAt, sourceLastAt.rounded() == sourceLastAt,
              (10...46).contains(trainingDates.count), (5...23).contains(calibrationDates.count), (5...23).contains(validationDates.count),
              dates.count <= 90, dates.allSatisfy(Self.dateKey), zip(dates, dates.dropFirst()).allSatisfy({ $0 < $1 }),
              horizons.map(\.minutes) == [15, 30] else { throw TargetResponseResearch.invalid }
        if current {
            guard createdAt <= now.timeIntervalSince1970 * 1000,
                  now.timeIntervalSince1970 - sourceLastAt / 1000 <= 30 * 86_400 else { throw TargetResponseResearch.invalid }
        }
        for horizon in horizons {
            let scores = horizon.validation
            guard horizon.errorBandF.isFinite, horizon.errorBandF >= 0.25,
                  [scores.modelMaeF, scores.persistenceMaeF, scores.simpleMaeF, scores.trendMaeF].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  scores.intervalCoverage.isFinite, (0...1).contains(scores.intervalCoverage),
                  scores.supportedFraction.isFinite, (0...1).contains(scores.supportedFraction),
                  !scores.passes || scores.meetsPolicy else { throw TargetResponseResearch.invalid }
        }
    }
    static func dateKey(_ value: String) -> Bool {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt; formatter.dateFormat = "yyyy-MM-dd"
        guard value.count == 10, let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

struct TargetResponsePreview: Codable, Sendable {
    struct Candidate: Codable, Sendable, Identifiable {
        struct Prediction: Codable, Sendable, Identifiable {
            let minutes: Int
            let waterF: Double
            let lowerF: Double
            let upperF: Double
            var id: Int { minutes }
        }
        let targetF: Double
        let reason: String
        let predictions: [Prediction]
        var id: Double { targetF }
    }
    let apiVersion: Int
    let side: Side
    let generatedAt: Double
    let activationAvailable: Bool
    let reason: String
    let candidates: [Candidate]
    func validate(side expectedSide: Side, now: Date) throws {
        guard apiVersion == 1, side == expectedSide, !activationAvailable,
              TargetResponseResearch.fresh(generatedAt, now: now, seconds: 90), candidates.count <= 2,
              Set(candidates.map(\.targetF)).count == candidates.count else { throw TargetResponseResearch.invalid }
        for candidate in candidates {
            guard candidate.targetF.isFinite, (55...110).contains(candidate.targetF),
                  candidate.predictions.isEmpty || candidate.predictions.map(\.minutes) == [15, 30] else { throw TargetResponseResearch.invalid }
            for prediction in candidate.predictions {
                guard [prediction.waterF, prediction.lowerF, prediction.upperF].allSatisfy({ $0.isFinite && (50...115).contains($0) }),
                      prediction.lowerF <= prediction.waterF, prediction.waterF <= prediction.upperF else { throw TargetResponseResearch.invalid }
            }
        }
    }
}
