import Foundation

/// An exact Health sample identity, retained only while its review screen is open.
struct HealthHRVEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: String
    let deviceID: String?
    let side: String?
    let start: Date
    let end: Date
    let milliseconds: Double
    let metric: String?
    let provenance: String?

    var hasRecordedSDNN: Bool { metric == "hrv_sdnn" && provenance == "recorded" }
}

struct HealthHRVScope: Equatable, Sendable {
    let source: String
    let deviceID: String
    let side: String
    let start: Date
    let end: Date

    func contains(_ entry: HealthHRVEntry) -> Bool {
        entry.source == source && entry.deviceID == deviceID
            && (entry.side == nil || entry.side == side)
            && entry.start >= start && entry.start < end
    }
    var isValid: Bool {
        !source.isEmpty && deviceID.count > side.count + 1 && deviceID.hasSuffix("-\(side)") && ["left", "right"].contains(side)
            && start.timeIntervalSince1970.isFinite && end.timeIntervalSince1970.isFinite
            && end > start && end.timeIntervalSince(start) <= 91 * 86400
    }
}

enum HealthHRVReviewError: LocalizedError {
    case unavailable, permission, changed, tooMany, selection
    var errorDescription: String? {
        switch self {
        case .unavailable: "HRV review is unavailable. Use your owner connection and pause HRV export first."
        case .permission: "Allow HRV access for sleepypod in Apple Health to review and remove its entries. Export stays paused."
        case .changed: "The Health entries, connection or Health choices changed. Read the entries again before removing anything else."
        case .tooMany: "There are too many entries to review safely at once. Choose a shorter period."
        case .selection: "Select unverified entries from the current review first."
        }
    }
}
