import Foundation

enum ComfortQualificationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case presenceEmpty = "presence_empty", presenceOccupied = "presence_occupied", cooling, warming
    case manualStop = "manual_stop", offlineRoutine = "offline_routine"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .presenceEmpty: "Empty-side presence"
        case .presenceOccupied: "Occupied-side presence"
        case .cooling: "Cooling response"
        case .warming: "Warming response"
        case .manualStop: "Manual stop"
        case .offlineRoutine: "Offline routine and wake alarm"
        }
    }
    var instructions: String {
        switch self {
        case .presenceEmpty: "Leave this side empty. Confirm the calibrated reading agrees with what you see."
        case .presenceOccupied: "Occupy this side. Confirm the calibrated reading agrees with what you see; this does not establish sleep."
        case .cooling: "Use the normal temperature controls, wait at least a minute, and confirm this side feels cooler without leaks or unusual noise. The warming test must use a target at least 2°F higher."
        case .warming: "Use the normal temperature controls, wait at least a minute, and confirm this side feels warmer without leaks or unusual noise. Use a target at least 2°F above the cooling test."
        case .manualStop: "After testing both temperatures, switch this side off using the normal controls. Confirm heating and cooling stopped. The controller also checks a fresh off report and the manual pause."
        case .offlineRoutine: "Attend a scheduled temperature change and wake alarm with internet, the phone and home server unavailable. Confirm the routine, alarm and cancellation worked. The journal proves acknowledgments; only your observation confirms the outage and physical behavior."
        }
    }
}

struct ComfortOwnerIdentity: Codable, Equatable, Sendable {
    struct Policy: Codable, Equatable, Sendable { let minimumF: Int; let maximumF: Int; let sensorAware: Bool; let followBedtime: Bool }
    let hardware: String
    let calibration: String
    let schedule: String
    let build: String
    let policy: Policy
    var valid: Bool {
        [hardware, calibration, schedule].allSatisfy(ComfortReviewInput.validDigest)
            && (7...40).contains(build.count) && build.allSatisfy { "0123456789abcdef".contains($0) }
            && (55...110).contains(policy.minimumF) && (policy.minimumF...110).contains(policy.maximumF)
    }
}

struct ComfortOwnerEvidence: Codable, Sendable {
    let identity: ComfortOwnerIdentity
    let observedAt: Double
    let presenceAt: Double?
    let presence: String
    let powered: Bool
    let offConfirmed: Bool
    let targetF: Double?
    let applicationId: String?
    let applicationAt: Double?
    let alarmAt: Double?
    let pausedUntil: Double
    var valid: Bool {
        identity.valid && ComfortOwnerValidation.time(observedAt) && ComfortOwnerValidation.time(pausedUntil, zero: true)
            && [presenceAt, applicationAt, alarmAt].allSatisfy { $0 == nil || ComfortOwnerValidation.time($0!) }
            && ["occupied", "empty", "unavailable"].contains(presence)
            && (applicationId == nil || UUID(uuidString: applicationId!) != nil)
            && (targetF == nil || targetF!.isFinite)
    }
}

struct ComfortQualification: Codable, Identifiable, Sendable {
    let id: String
    let kind: ComfortQualificationKind
    let at: Double
    let outcome: String
    let note: String
    let evidence: ComfortOwnerEvidence
    var valid: Bool {
        UUID(uuidString: id) != nil && ComfortOwnerValidation.time(at) && ["confirmed", "needs_retest"].contains(outcome)
            && note.utf16.count <= 2000 && evidence.valid
    }
    func label(identity: ComfortOwnerIdentity?) -> String {
        guard let identity else { return "Waiting for fresh controller identity" }
        guard identity == evidence.identity else { return "Earlier configuration; repeat" }
        return outcome == "confirmed" ? "Owner confirmed" : "Needs retest"
    }
}

struct ComfortOwnerNight: Codable, Identifiable, Sendable {
    let summary: ComfortNightSummary
    let reviewId: Int
    let lastObservationId: Int
    let eligibleMs: Double
    var id: String { summary.id }
    var valid: Bool {
        ComfortReviewInput.validDigest(id) && ComfortReviewInput.validDigest(summary.digest)
            && PersonalComfortDates.date(summary.localDate) != nil && reviewId > 0 && lastObservationId > 0
            && ComfortOwnerValidation.time(eligibleMs, zero: true)
    }
}

struct ComfortOwnerApplication: Codable, Sendable {
    let requestId: String
    let segment: String
    let targetF: Double
    let previousF: Double
    let createdAt: Double
    let reservedAt: Double
    let finishedAt: Double?
    let outcome: String
    let receiptId: String?
    var uncertain: Bool { outcome != "acknowledged" }
    var valid: Bool {
        UUID(uuidString: requestId) != nil && !segment.isEmpty && segment.utf16.count <= 1000
            && (55...110).contains(targetF) && (55...110).contains(previousF)
            && ComfortOwnerValidation.time(createdAt, zero: true) && ComfortOwnerValidation.time(reservedAt, zero: true) && createdAt <= reservedAt
            && (finishedAt == nil || ComfortOwnerValidation.time(finishedAt!, zero: true) && finishedAt! >= reservedAt)
            && ["attempting", "acknowledged", "unknown"].contains(outcome)
            && (receiptId == nil || UUID(uuidString: receiptId!) != nil)
            && (outcome != "acknowledged" || finishedAt != nil && receiptId != nil)
    }
}

struct ComfortOwnerStatus: Codable, Sendable {
    let apiVersion: Int
    let generatedAt: Double
    let side: Side
    let identity: ComfortOwnerIdentity?
    let qualifications: [ComfortQualification]
    let nights: [ComfortOwnerNight]
    let reasons: [String]
    let active: Bool
    let canActivate: Bool
    let application: ComfortOwnerApplication?
    func validate(side expected: Side) throws {
        guard apiVersion == 1, side == expected, ComfortOwnerValidation.time(generatedAt), identity?.valid != false,
              ComfortOwnerValidation.records(qualifications, nights), application?.valid != false,
              !(active && canActivate), !(active || canActivate) || identity != nil,
              !(active || canActivate) || ComfortOwnerValidation.qualified(qualifications, nights, identity: identity),
              reasons.count <= 100, reasons.allSatisfy({ $0.utf16.count <= 4000 }) else { throw ComfortOwnerValidation.invalid }
    }
}

enum ComfortOwnerPurpose: String, Codable, Sendable { case qualification, activation, resolution }
struct ComfortOwnerReview: Codable, Identifiable, Sendable {
    struct Snapshot: Codable, Sendable {
        let identity: ComfortOwnerIdentity
        let qualifications: [ComfortQualification]
        let nights: [ComfortOwnerNight]
        let evidence: ComfortOwnerEvidence?
        let application: ComfortOwnerApplication?
    }
    let id: String
    let side: Side
    let at: Double
    let expiresAt: Double
    let purpose: ComfortOwnerPurpose
    let kind: ComfortQualificationKind?
    let snapshot: Snapshot
    var title: String {
        switch purpose {
        case .qualification: kind?.title ?? "Attended check"
        case .activation: "Activate thermal comfort"
        case .resolution: "Return to Preview"
        }
    }
    var confirmation: String {
        switch purpose {
        case .qualification: "I attended this check and confirm the physical observations described above."
        case .activation: "I reviewed these observations and authorize bounded thermal adjustments for this side."
        case .resolution: "I reviewed the uncertain outcome and want to return to Preview without retrying it."
        }
    }
    func validate(for request: ComfortOwnerPrepare) throws {
        guard UUID(uuidString: id) != nil, side == request.side, purpose == request.purpose, kind == request.kind,
              ComfortOwnerValidation.time(at), ComfortOwnerValidation.time(expiresAt), expiresAt > at, expiresAt - at <= 60_000,
              snapshot.identity.valid, ComfortOwnerValidation.records(snapshot.qualifications, snapshot.nights),
              snapshot.application?.valid != false, snapshot.evidence?.valid != false,
              snapshot.evidence == nil || snapshot.evidence?.identity == snapshot.identity,
              (purpose == .qualification) == (kind != nil), purpose == .activation || snapshot.evidence != nil,
              purpose != .activation || ComfortOwnerValidation.qualified(snapshot.qualifications, snapshot.nights, identity: snapshot.identity)
                && snapshot.application?.uncertain != true,
              purpose != .resolution || snapshot.application?.uncertain == true else { throw ComfortOwnerValidation.invalid }
    }
}

struct ComfortOwnerPrepare: Codable, Sendable {
    let side: Side
    let purpose: ComfortOwnerPurpose
    let kind: ComfortQualificationKind?
    enum CodingKeys: String, CodingKey { case side, purpose, kind }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(side, forKey: .side); try values.encode(purpose, forKey: .purpose); try values.encode(kind, forKey: .kind)
    }
}
struct ComfortOwnerConfirm: Codable, Sendable { let side: Side; let id: String; let confirmed: Bool; let note: String }
struct ComfortOwnerRetest: Codable, Sendable { let side: Side; let kind: ComfortQualificationKind; let expectedId: String }
struct ComfortOwnerReceipt: Codable, Sendable { let saved: Bool }

enum ComfortOwnerValidation {
    static var invalid: APIError { .serverError(message: "The qualification response is incomplete or does not match this review. Refresh its evidence.") }
    static func time(_ value: Double, zero: Bool = false) -> Bool { value.isFinite && value >= (zero ? 0 : 1) && value <= 8_640_000_000_000_000 && value.rounded(.down) == value }
    static func records(_ qualifications: [ComfortQualification], _ nights: [ComfortOwnerNight]) -> Bool {
        qualifications.count <= 6 && qualifications.allSatisfy(\.valid) && Set(qualifications.map(\.kind)).count == qualifications.count
            && Set(qualifications.map(\.id)).count == qualifications.count && nights.count <= 7
            && nights.allSatisfy(\.valid) && Set(nights.map(\.id)).count == nights.count
    }
    static func qualified(_ qualifications: [ComfortQualification], _ nights: [ComfortOwnerNight], identity: ComfortOwnerIdentity?) -> Bool {
        guard let identity, !identity.policy.followBedtime, qualifications.count == 6, nights.count == 7 else { return false }
        return qualifications.allSatisfy { $0.outcome == "confirmed" && $0.evidence.identity == identity }
            && nights.allSatisfy { $0.eligibleMs >= 14_400_000 && $0.summary.state == "closed" && $0.summary.reviewable }
    }
}
