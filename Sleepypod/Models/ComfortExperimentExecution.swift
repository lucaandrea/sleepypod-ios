import Foundation

struct ComfortExperimentExecution: ComfortExperimentEnvelope, Equatable {
    struct Review: Decodable, Equatable, Sendable {
        let id: String
        let planHash: String
        let createdAt: Int64
        let expiresAt: Int64
        let sides: [Side]
    }
    struct Admission: Decodable, Equatable, Sendable {
        let id: String
        let admittedAt: Int64
        let endsAt: Int64
        let revokedAt: Int64?
        let reason: String?
        let sides: [Side]
    }
    struct Application: Decodable, Equatable, Sendable, Identifiable {
        struct Resolution: Decodable, Equatable, Sendable { let observedAt: Int64; let resolvedAt: Int64; let targetF: Double }
        let id: String
        let side: Side
        let requestedTargetF: Int
        let attemptedAt: Int64
        let outcome: String
        let acknowledgment: String
        let finishedAt: Int64?
        let resolution: Resolution?
        var uncertain: Bool { ["attempting", "unknown"].contains(outcome) }
    }
    let version: Int
    let generatedAt: Int64
    let scope: ComfortExperimentScope
    let planId: String
    let planStatus: String
    let controllerRunning: Bool
    let state: String
    var review: Review?
    let admission: Admission?
    let applications: [Application]
    private func validSides(_ values: [Side]) -> Bool { !values.isEmpty && values.count <= 2 && Set(values).count == values.count }
    func validate(record: ComfortExperimentRecord) throws {
        try ComfortExperimentContract.require(planId == record.plan.id && planStatus == record.status
            && applications.count <= 2 && ["not_admitted", "admitted", "revoked", "ended"].contains(state))
        if let review {
            try ComfortExperimentContract.require(ComfortExperimentContract.identifier(review.id) && ComfortExperimentContract.hash(review.planHash)
                && ComfortExperimentContract.instant(review.createdAt) && review.createdAt <= generatedAt
                && review.expiresAt > generatedAt && review.expiresAt - review.createdAt <= 60_000 && validSides(review.sides))
        }
        guard let admission else {
            try ComfortExperimentContract.require(state == "not_admitted" && applications.isEmpty); return
        }
        guard let schedule = record.plan.schedule else { throw HouseholdFailure.invalid }
        try ComfortExperimentContract.require(ComfortExperimentContract.identifier(admission.id) && validSides(admission.sides)
            && ComfortExperimentContract.instant(admission.admittedAt) && admission.admittedAt <= generatedAt
            && admission.admittedAt < schedule.windows[0].windowStart && admission.endsAt == schedule.windows.last?.windowEnd
            && (admission.revokedAt == nil) == (admission.reason == nil)
            && (admission.reason?.utf16.count ?? 0) <= 1000)
        let expectedState = admission.revokedAt != nil ? "revoked" : admission.endsAt <= generatedAt ? "ended" : "admitted"
        try ComfortExperimentContract.require(state == expectedState
            && (admission.revokedAt.map { $0 >= admission.admittedAt && $0 <= generatedAt } ?? true)
            && Set(applications.map(\.id)).count == applications.count && Set(applications.map(\.side)).count == applications.count)
        for application in applications {
            let window = schedule.windows.first { application.attemptedAt >= $0.windowStart && application.attemptedAt < $0.windowEnd }
            let night = record.plan.nights.first { $0.date == window?.date }
            try ComfortExperimentContract.require(ComfortExperimentContract.identifier(application.id) && admission.sides.contains(application.side)
                && application.attemptedAt >= admission.admittedAt && application.attemptedAt <= generatedAt
                && night?.targetF == application.requestedTargetF
                && ["attempting", "acknowledged", "unknown", "resolved"].contains(application.outcome)
                && ["accepted_not_physically_verified", "unconfirmed"].contains(application.acknowledgment)
                && (application.outcome == "acknowledged") == (application.acknowledgment == "accepted_not_physically_verified")
                && (application.outcome != "acknowledged" || application.finishedAt != nil)
                && (application.finishedAt.map { $0 >= application.attemptedAt && $0 <= generatedAt } ?? true)
                && (application.outcome == "resolved") == (application.resolution != nil))
            if let resolution = application.resolution {
                try ComfortExperimentContract.require(resolution.observedAt > max(application.attemptedAt, application.finishedAt ?? 0)
                    && resolution.resolvedAt >= resolution.observedAt && resolution.resolvedAt <= generatedAt
                    && (55...110).contains(resolution.targetF))
            }
        }
    }
}
