import Foundation

struct ComfortNightSummary: Codable, Sendable {
    struct Metadata: Codable, Sendable { let session: String; let start: Double; let end: Double; let timezone: String }
    struct Range: Codable, Sendable { let minimum: Double; let maximum: Double }
    struct Reason: Codable, Sendable { let message: String; let count: Int }
    struct Gap: Codable, Sendable { let from: Double; let to: Double }
    let id: String
    let digest: String
    let metadata: Metadata
    let localDate: String
    let state: String
    let firstAt: Double
    let lastAt: Double
    let observationCount: Int
    let occupiedObservationMs: Double
    let minimumOccupiedObservationMs: Double
    let occupiedCount: Int
    let eligibleCount: Int
    let sensorReadyCount: Int
    let deviceFreshCount: Int
    let manualPauseCount: Int
    let proposedRangeF: Range?
    let reportedRangeF: Range?
    let reasons: [Reason]
    let gaps: [Gap]
    let gapCount: Int
    let configurations: Int
    let runs: Int
    let builds: [String]
    let issues: [String]
    let reviewable: Bool
}
struct ComfortNightReview: Codable, Equatable, Sendable {
    let id: Int
    let at: Double
    let digest: String
    let outcome: String
    let confirmedActualNight: Bool
    let note: String
}
struct ComfortNightItem: Codable, Identifiable, Sendable {
    let summary: ComfortNightSummary
    let review: ComfortNightReview?
    let reviewCurrent: Bool
    let countsAsOwnerConfirmedNight: Bool
    var id: String { summary.id }
    var label: String {
        if summary.state == "source_expired" { return "Source expired" }
        if review != nil && !reviewCurrent { return "Review needs refreshing" }
        if countsAsOwnerConfirmedNight { return "Owner confirmed" }
        if review?.outcome == "needs_retest" { return "Retest requested" }
        return summary.state == "collecting" ? "Collecting" : summary.reviewable ? "Ready for review" : "Needs more evidence"
    }
}
struct ComfortNightList: Codable, Sendable {
    let apiVersion: Int
    let generatedAt: Double
    let side: Side
    let items: [ComfortNightItem]
    let targetNights: Int
    let ownerConfirmedNights: Int
    let activationAvailable: Bool
    func validate(side expected: Side) throws {
        guard apiVersion == 1, side == expected, targetNights == 7, ownerConfirmedNights >= 0, !activationAvailable,
              Set(items.map(\.id)).count == items.count, items.allSatisfy({ ComfortReviewInput.validDigest($0.id) && ComfortReviewInput.validDigest($0.summary.digest) }) else {
            throw APIError.serverError(message: "The controller returned an unsupported Preview report list.")
        }
    }
}
struct ComfortNightObservation: Codable, Identifiable, Sendable {
    let id: Int
    let at: Double
    let eligible: Bool
    let proposedF: Double?
    let reportedF: Double?
    let message: String
    let evidence: JSONValue
}
struct ComfortNightDetail: Codable, Sendable {
    let summary: ComfortNightSummary
    let review: ComfortNightReview?
    let reviewCurrent: Bool
    let countsAsOwnerConfirmedNight: Bool
    let observations: [ComfortNightObservation]
    let nextAfterId: Int?
    var item: ComfortNightItem { .init(summary: summary, review: review, reviewCurrent: reviewCurrent, countsAsOwnerConfirmedNight: countsAsOwnerConfirmedNight) }
    func validate(id: String, after: Int? = nil) throws {
        let identifiers = observations.map(\.id)
        guard summary.id == id, ComfortReviewInput.validDigest(summary.digest), observations.count <= 200,
              identifiers.allSatisfy({ $0 > (after ?? 0) }), identifiers == identifiers.sorted(), Set(identifiers).count == identifiers.count,
              nextAfterId == nil || (nextAfterId == identifiers.last && nextAfterId! > (after ?? 0)) else {
            throw APIError.serverError(message: "The report page does not match the requested night. Refresh the report.")
        }
    }
}
struct ComfortReviewInput: Codable, Equatable, Sendable {
    let side: Side
    let id: String
    let digest: String
    let expectedReviewId: Int?
    var outcome = "needs_retest"
    var confirmedActualNight = false
    var note = ""
    init(side: Side, report: ComfortNightDetail) {
        self.side = side; id = report.summary.id; digest = report.summary.digest; expectedReviewId = report.review?.id
    }
    // The first review must encode null, since an omitted expected revision is invalid.
    enum CodingKeys: String, CodingKey { case side, id, digest, expectedReviewId, outcome, confirmedActualNight, note }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(side, forKey: .side); try values.encode(id, forKey: .id); try values.encode(digest, forKey: .digest)
        try values.encode(expectedReviewId, forKey: .expectedReviewId); try values.encode(outcome, forKey: .outcome)
        try values.encode(confirmedActualNight, forKey: .confirmedActualNight); try values.encode(note.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .note)
    }
    func validate(report: ComfortNightDetail) throws {
        guard id == report.summary.id, digest == report.summary.digest, expectedReviewId == report.review?.id,
              report.summary.state == "closed", Self.validDigest(id), Self.validDigest(digest), ["reviewed", "needs_retest"].contains(outcome),
              outcome != "reviewed" || (confirmedActualNight && report.summary.reviewable), note.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 2000 else {
            throw APIError.serverError(message: "Refresh this closed report and explicitly confirm an eligible actual night before recording that conclusion.")
        }
    }
    static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}
