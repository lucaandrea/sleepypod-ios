import Foundation

struct ComfortExperimentScope: Codable, Equatable, Sendable {
    let kind: String
    var installationId: String?
    var podId: String?
    var householdId: String?
    var accountId: String?
    var sleeperId: String?
    var sessionRevision: Int?
    var assignmentRevision: Int?
    var householdRevision: Int?
    static func personal(_ session: HouseholdSession) -> Self {
        .init(kind: "personal", podId: session.podId, householdId: session.householdId, accountId: session.accountId,
            sleeperId: session.selfSleeperId, sessionRevision: session.sessionRevision,
            assignmentRevision: session.assignmentRevision, householdRevision: session.householdRevision)
    }
    func validate() throws {
        if kind == "legacy" {
            try ComfortExperimentContract.require(installationId.map(ComfortExperimentContract.identifier) == true
                && [podId, householdId, accountId, sleeperId].allSatisfy { $0 == nil }
                && [sessionRevision, assignmentRevision, householdRevision].allSatisfy { $0 == nil })
        } else {
            try ComfortExperimentContract.require(kind == "personal" && installationId == nil
                && [podId, householdId, accountId, sleeperId].allSatisfy { $0.map(ComfortExperimentContract.identifier) == true }
                && [sessionRevision, assignmentRevision, householdRevision].allSatisfy { $0.map(HouseholdValidation.revision) == true })
        }
    }
}

protocol ComfortExperimentEnvelope: Decodable, Sendable {
    var version: Int { get }
    var generatedAt: Int64 { get }
    var scope: ComfortExperimentScope { get }
}
extension ComfortExperimentEnvelope {
    func validateEnvelope(scope expected: ComfortExperimentScope, now: Int64) throws {
        try scope.validate()
        try ComfortExperimentContract.require(version == 1 && scope == expected && ComfortExperimentContract.instant(generatedAt)
            && generatedAt <= now + 60_000 && generatedAt >= now - 120_000)
    }
}

struct ComfortExperimentAvailability: Decodable, Equatable, Sendable {
    let context: ComfortExperimentContext?
    let reason: String
    func validate() throws {
        try context?.validate(); try ComfortExperimentContract.require(reason.utf16.count <= 2000)
    }
}
struct ComfortExperimentLibrary: ComfortExperimentEnvelope, Equatable {
    struct Item: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let revision: String
        let status: String
        let createdAt: Int64
        let updatedAt: Int64
        let firstNightDate: String
        let baselineF: Int
        let variantF: Int
        let contextCurrent: Bool
    }
    let version: Int
    let generatedAt: Int64
    let scope: ComfortExperimentScope
    let execution: String
    let availability: ComfortExperimentAvailability
    let nextId: String?
    let experiments: [Item]
    func validate() throws {
        try availability.validate()
        try ComfortExperimentContract.require(execution == "planning_only" && experiments.count <= 20
            && Set(experiments.map(\.id)).count == experiments.count && (nextId.map(ComfortExperimentContract.identifier) ?? true))
        for item in experiments {
            try ComfortExperimentContract.require([item.id, item.revision].allSatisfy(ComfortExperimentContract.identifier)
                && ["planned", "stopped"].contains(item.status) && ComfortExperimentContract.instant(item.createdAt)
                && item.createdAt <= item.updatedAt && item.updatedAt <= generatedAt && ComfortExperimentContract.date(item.firstNightDate)
                && [item.baselineF, item.variantF].allSatisfy(ComfortExperimentContract.temperature))
        }
    }
}
struct ComfortExperimentReview: ComfortExperimentEnvelope, Equatable {
    let version: Int
    let generatedAt: Int64
    let scope: ComfortExperimentScope
    let execution: String
    let availability: ComfortExperimentAvailability
    let reviewId: String
    let planHash: String
    let expiresAt: Int64
    let plan: ComfortExperimentPlan
    let nights: [ComfortExperimentNight]
    let schedule: ComfortExperimentSchedule
    let notice: String
    func validate(proposal: ComfortExperimentProposal) throws {
        try plan.validate(); try availability.validate()
        try ComfortExperimentContract.require(execution == "planning_only" && plan.version == 2 && reviewId == plan.id
            && ComfortExperimentContract.hash(planHash) && expiresAt > generatedAt && expiresAt - generatedAt <= 300_000
            && plan.variantF == proposal.variantF && schedule.requestedFirstNightDate == proposal.firstNightDate
            && schedule == plan.schedule && nights == plan.nights && notice.utf16.count <= 2000)
    }
}
struct ComfortExperimentProposal: Encodable, Equatable, Sendable {
    let firstNightDate: String
    let variantF: Int
    func validate() throws {
        try ComfortExperimentContract.require(ComfortExperimentContract.date(firstNightDate) && ComfortExperimentContract.temperature(variantF))
    }
}
struct ComfortExperimentDetail: ComfortExperimentEnvelope, Equatable {
    struct ScoredNight: Decodable, Equatable, Sendable, Identifiable {
        let date: String
        let pair: Int
        let period: Int
        let role: String
        let arm: String
        let targetF: Int
        let usable: Bool
        let exclusions: [String]
        let comfort: Double?
        let unwantedAdjustments: Int?
        let problem: Bool?
        var id: String { date }
        var assigned: ComfortExperimentNight { .init(date: date, pair: pair, period: period, role: role, arm: arm, targetF: targetF) }
    }
    struct Arm: Decodable, Equatable, Sendable { let assigned: Int; let scored: Int; let usable: Int; let missing: Int; let meanComfort: Double? }
    struct Comparison: Decodable, Equatable, Sendable {
        struct Arms: Decodable, Equatable, Sendable { let baseline: Arm; let variant: Arm }
        struct Difference: Decodable, Equatable, Sendable { let pair: Int; let comfort: Double; let unwantedAdjustments: Int }
        let nights: [ScoredNight]
        let arms: Arms
        let pairedDifferences: [Difference]
        let meanPairedComfortDifference: Double?
        let recommendation: String
        let reason: String
        let interpretation: String
    }
    let version: Int
    let generatedAt: Int64
    let scope: ComfortExperimentScope
    let execution: String
    let record: ComfortExperimentRecord
    let contextCurrent: Bool
    let contextReason: String
    let comparison: Comparison
    func validate(id: String) throws {
        try record.validate(generatedAt: generatedAt)
        try ComfortExperimentContract.require(execution == "planning_only" && record.plan.id == id && contextReason.utf16.count <= 2000
            && comparison.nights.map(\.assigned) == record.plan.nights && comparison.reason.utf16.count <= 2000
            && comparison.interpretation == "personal_comfort_comparison_not_sleep_or_causal_proof"
            && ["consider_variant", "keep_baseline", "inconclusive"].contains(comparison.recommendation)
            && comparison.pairedDifferences.count <= 4 && (comparison.meanPairedComfortDifference.map { (-10...10).contains($0) } ?? true))
        for arm in [comparison.arms.baseline, comparison.arms.variant] {
            try ComfortExperimentContract.require([arm.assigned, arm.scored, arm.usable, arm.missing].allSatisfy { (0...16).contains($0) }
                && arm.usable <= arm.scored && arm.scored <= arm.assigned && (arm.meanComfort.map { (0...10).contains($0) } ?? true))
        }
        let exclusions = ["missing_exposure", "source_withdrawn", "context_changed", "preview_only", "wrong_window", "wake_overlap",
            "wrong_target", "insufficient_coverage", "manual_change", "uncertain_command", "safety_interruption", "ambiguous_sleeper",
            "missing_feedback", "partial_night", "invalid_feedback_clock", "settling_unverified"]
        for night in comparison.nights {
            try ComfortExperimentContract.require(night.exclusions.count <= 16 && night.exclusions.allSatisfy(exclusions.contains)
                && (night.comfort.map { (0...10).contains($0) } ?? true)
                && (night.unwantedAdjustments.map { $0 >= 0 } ?? true))
        }
        for difference in comparison.pairedDifferences {
            try ComfortExperimentContract.require((0...3).contains(difference.pair) && (-10...10).contains(difference.comfort))
        }
    }
}
