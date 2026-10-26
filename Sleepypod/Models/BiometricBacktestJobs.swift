import Foundation

enum BiometricEvaluationSplit: String, Codable, CaseIterable, Sendable {
    case tuning, validation, holdout
    var title: String { rawValue.capitalized }
}
struct BiometricBacktestJob: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, running, cancellationRequested = "cancel_requested", cancelled, succeeded, failed, interrupted
        var title: String {
            switch self {
            case .queued: "Queued"
            case .running: "Running"
            case .cancellationRequested: "Cancellation requested"
            case .cancelled: "Cancelled"
            case .succeeded: "Execution completed"
            case .failed: "Failed"
            case .interrupted: "Interrupted"
            }
        }
        var terminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
        var cancellable: Bool { self == .queued || self == .running || self == .interrupted }
    }
    enum Scope: String, Codable, Sendable {
        case comparison = "original_readings_comparison", stages = "stage_rules_on_original_readings", waveform = "retained_waveform_replay"
        var title: String {
            switch self {
            case .comparison: "Original stored-reading comparison"
            case .stages: "Stage rules on original readings"
            case .waveform: "Retained waveform replay"
            }
        }
    }
    struct Progress: Codable, Equatable, Sendable { let phase: String; let completedNights: Int; let totalNights: Int }
    struct Configuration: Codable, Equatable, Sendable, Identifiable {
        let label: String
        let revisionId: String?
        let hash: String
        var id: String { label }
    }
    let id: String
    let experimentId: String
    let state: State
    let attempt: Int
    let progress: Progress
    let cancellationRequestedAtMs: Double?
    let error: String?
    let createdAtMs: Double
    let updatedAtMs: Double
    let datasetId: String
    let datasetHash: String
    let evaluatorBuildHash: String
    let split: BiometricEvaluationSplit
    let configurations: [Configuration]
    let evaluationScope: Scope
    var validIdentity: Bool {
        UUID(uuidString: id) != nil && UUID(uuidString: experimentId) != nil && UUID(uuidString: datasetId) != nil
        && BiometricBacktestInput.isHash(datasetHash) && BiometricBacktestInput.isHash(evaluatorBuildHash)
        && attempt >= 0 && progress.completedNights >= 0 && progress.totalNights >= progress.completedNights
        && [createdAtMs, updatedAtMs].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 9007199254740991 && $0.rounded() == $0 }
        && (1...3).contains(configurations.count) && Set(configurations.map(\.label)).count == configurations.count
        && configurations.allSatisfy { BiometricBacktestInput.isHash($0.hash) && ($0.revisionId.map { UUID(uuidString: $0) != nil } ?? true) }
    }
}
struct BiometricBacktestPage: Codable, Sendable {
    struct Cursor: Codable, Equatable, Sendable { let createdAtMs: Double; let id: String }
    let items: [BiometricBacktestJob]
    let nextCursor: Cursor?
}
struct BiometricBacktestSubmission: Codable, Equatable, Sendable {
    let experimentId: String
    let candidateRevisionId: String
    let expectedBindingGeneration: Int
    let split: BiometricEvaluationSplit
    let idempotencyKey: String
    func validated() throws -> Self {
        _ = try BiometricBacktestInput.identifier(experimentId)
        _ = try BiometricBacktestInput.identifier(candidateRevisionId)
        guard expectedBindingGeneration >= 0, expectedBindingGeneration <= 9007199254740991,
              (1...200).contains(idempotencyKey.utf16.count) else { throw BiometricBacktestInput.error("Review an exact candidate and current baseline before submitting.") }
        return self
    }
}
