import Foundation

struct PersonalHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    struct Attribution: Codable, Equatable, Sendable {
        enum Mode: String, Codable, Sendable { case soloMerged = "solo_merged", assigned }
        enum Basis: String, Codable, Sendable { case legacyReview = "legacy_owner_review", arrangement = "verified_arrangement" }
        let epochId: String
        let mode: Mode
        let basis: Basis
        let identity: String
    }
    let id: String
    let sleeperId: String
    let startsAt: Int64
    let endsAt: Int64
    let recordedSide: Side
    let payload: PersonalHistoryPayload
    let attribution: Attribution

    func validate(sleeperId expectedSleeper: String) throws {
        guard HouseholdValidation.identifier(id), HouseholdValidation.identifier(sleeperId),
              HouseholdValidation.identifier(attribution.epochId),
              PersonalHistoryQuery.validTime(startsAt), PersonalHistoryQuery.validTime(endsAt),
              endsAt > startsAt, endsAt - startsAt <= 86_400_000,
              attribution.identity == "reviewed_arrangement_not_biometric_identification" else { throw HouseholdFailure.invalid }
        guard sleeperId == expectedSleeper else { throw HouseholdFailure.changedIdentity }
        try payload.validate(intervalMilliseconds: endsAt - startsAt)
    }
}
