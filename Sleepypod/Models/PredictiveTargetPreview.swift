import Foundation

/// A bounded research comparison is not a temperature request or an activation capability.
struct PredictiveTargetPreview: Codable, Sendable {
    enum Disposition: String, Codable, Sendable { case withheld, hold, candidate }
    struct Comparison: Codable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case hold, step }
        let targetF: Double
        let kind: Kind
        let predictions: [TargetResponsePreview.Candidate.Prediction]
        let bestErrorF: Double?
        let worstErrorF: Double?
        let reason: String
        var id: Double { targetF }
    }
    let apiVersion: Int
    let policy: String
    let side: Side
    let generatedAt: Double
    let mode: String
    let activationAvailable: Bool
    let objective: String
    let disposition: Disposition
    let currentTargetF: Double?
    let desiredWaterF: Double?
    let proposedTargetF: Double?
    let expiresAt: Double?
    let minimumF: Double?
    let maximumF: Double?
    let comparisons: [Comparison]
    let reason: String

    func validate(side expected: Side, now: Date) throws {
        guard apiVersion == 1, policy == "bounded-water-tracking-v1", side == expected,
              mode == "research_preview", !activationAvailable, objective == "bounded-routine-water-target",
              TargetResponseResearch.fresh(generatedAt, now: now, seconds: 15),
              [currentTargetF, proposedTargetF, minimumF, maximumF].allSatisfy({ value in value.map(Self.target) ?? true }),
              desiredWaterF.map({ $0.isFinite && (55...110).contains($0) }) ?? true,
              comparisons.count <= 3, Set(comparisons.map(\.targetF)).count == comparisons.count,
              comparisons.filter({ $0.kind == .hold }).count <= 1 else { throw TargetResponseResearch.invalid }
        for comparison in comparisons {
            guard Self.target(comparison.targetF), let currentTargetF,
                  comparison.kind == .hold ? comparison.targetF == currentTargetF : abs(comparison.targetF - currentTargetF) == 1 else { throw TargetResponseResearch.invalid }
            try validate(comparison)
        }
        if disposition == .withheld {
            guard proposedTargetF == nil, expiresAt == nil else { throw TargetResponseResearch.invalid }
            return
        }
        guard let currentTargetF, let desiredWaterF, let proposedTargetF, let minimumF, let maximumF,
              minimumF <= maximumF, (minimumF...maximumF).contains(proposedTargetF), (minimumF...maximumF).contains(desiredWaterF),
              let expiresAt, expiresAt.isFinite, expiresAt.rounded() == expiresAt,
              expiresAt > now.timeIntervalSince1970 * 1000, expiresAt > generatedAt, expiresAt - generatedAt <= 15_000,
              let hold = comparisons.first(where: { $0.kind == .hold }), hold.targetF == currentTargetF, hold.predictions.count == 2,
              let selection = comparisons.first(where: { $0.targetF == proposedTargetF }), selection.predictions.count == 2,
              (disposition == .hold) == (selection.kind == .hold) else { throw TargetResponseResearch.invalid }
    }

    private func validate(_ comparison: Comparison) throws {
        if comparison.predictions.isEmpty {
            guard comparison.bestErrorF == nil, comparison.worstErrorF == nil else { throw TargetResponseResearch.invalid }
            return
        }
        guard comparison.predictions.map(\.minutes) == [15, 30],
              let best = comparison.bestErrorF, let worst = comparison.worstErrorF,
              best.isFinite, worst.isFinite, best >= 0, worst >= best else { throw TargetResponseResearch.invalid }
        for value in comparison.predictions {
            guard [value.waterF, value.lowerF, value.upperF].allSatisfy({ $0.isFinite && (50...115).contains($0) }),
                  value.lowerF <= value.waterF, value.waterF <= value.upperF else { throw TargetResponseResearch.invalid }
        }
    }
    private static func target(_ value: Double) -> Bool { value.isFinite && value.rounded() == value && (55...110).contains(value) }
}
