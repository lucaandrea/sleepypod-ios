import Foundation

struct ControllerBuild: Codable, Equatable, Sendable {
    let branch: String
    let commitHash: String
    let commitTitle: String
    let buildDate: String
    let version: String?
    var knownIdentity: Bool { Self.known(commitHash) || Self.known(buildDate) }
    static func known(_ value: String) -> Bool { !value.isEmpty && value.lowercased() != "unknown" }
    func changed(from baseline: Self) -> Bool {
        (Self.known(commitHash) && Self.known(baseline.commitHash) && commitHash != baseline.commitHash)
            || (Self.known(buildDate) && Self.known(baseline.buildDate) && buildDate != baseline.buildDate)
    }
}
enum ControllerUpdateChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case main, dev
    var id: String { rawValue }
    var title: String { self == .main ? "Stable · main" : "Development · dev" }
}
struct ControllerUpdateSnapshot: Sendable {
    let build: ControllerBuild
    let internetBlocked: Bool
    let preservesInstalledRepository: Bool
}
struct ControllerUpdateReceipt: Codable, Equatable, Sendable {
    let triggered: Bool
    let branch: String
    let repository: String
    let message: String
}
struct ControllerUpdateReview: Equatable, Sendable {
    let build: ControllerBuild
    let channel: ControllerUpdateChannel
    let internetBlocked: Bool
    let readAt: Date
}
/// A retained request is an observation record, never permission to repeat the update POST.
struct ControllerUpdateAttempt: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case observing, changedBuild, unconfirmed }
    let id: UUID
    let baseline: ControllerBuild
    let channel: ControllerUpdateChannel
    let internetWasBlocked: Bool
    let startedAt: Date
    var receipt: ControllerUpdateReceipt?
    var sawConnectionGap = false
    var lastBuild: ControllerBuild?
    var outcome: Outcome = .observing
    var dispatchError: String?
    var lastReadError: String?
    var networkBlocked: Bool?
    var lastVersionReadAt: Date?
    var lastNetworkReadAt: Date?
    var restoreError: String?
    var timedOut: Bool { outcome == .unconfirmed }
    var title: String {
        switch outcome {
        case .changedBuild: "Controller reports a changed build"
        case .unconfirmed: "Update outcome is unconfirmed"
        case .observing: sawConnectionGap && lastBuild == baseline ? "Connection resumed · build unchanged" : "Waiting for the controller update"
        }
    }
    var needsNetworkRestore: Bool { internetWasBlocked && networkBlocked == false }
}
