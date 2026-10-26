import Foundation

struct ReplaySession: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let side: Side
    let startMs: Double
    let endMs: Double
    let sleepDurationSeconds: Double
    let timesExitedBed: Int
}
struct ReplaySessionPage: Codable, Sendable {
    struct Cursor: Codable, Equatable, Sendable { let startMs: Double; let id: Int }
    let items: [ReplaySession]
    let nextCursor: Cursor?
}
struct ReplayCoverage: Codable, Equatable, Sendable {
    struct Gap: Codable, Equatable, Sendable { let startMs: Double; let endMs: Double }
    let count: Int
    let duplicateTimestamps: Int
    let firstMs: Double?
    let lastMs: Double?
    let expectedCadenceMs: Double
    let gaps: [Gap]
    let gapDurationMs: Double
    let interpretation: String
}
struct ReplaySessionCapabilities: Codable, Equatable, Sendable {
    struct Processed: Codable, Equatable, Sendable {
        let vitals: ReplayCoverage
        let movement: ReplayCoverage
        let legacyUnknownProvenanceCount: Int
    }
    struct Metric: Codable, Equatable, Sendable { let metric: String; let count: Int }
    let session: ReplaySession
    let processed: Processed
    let referenceMetrics: [Metric]
    let comparison: Bool
    let stageReplay: Bool
    let signalReplay: Bool
    let rawWaveforms: String
    let limitations: [String]
}
struct BiometricDatasetManifest: Codable, Equatable, Sendable {
    struct Parent: Codable, Equatable, Sendable { let id: String; let contentHash: String }
    struct Cohort: Codable, Equatable, Identifiable, Sendable {
        let cohortId: String
        let nightLabels: [String]
        let sessionIds: [Int]
        let startMs: Double
        let endMs: Double
        let split: String
        var id: String { cohortId }
    }
    struct SplitProtocol: Codable, Equatable, Sendable {
        struct Runtime: Codable, Equatable, Sendable { let icu: String; let tz: String }
        let version: String
        let timezone: String
        let timezoneRuntime: Runtime
        let grouping: String
        let assignments: [Cohort]
        let evidence: String
        let limitations: [String]
    }
    struct Coverage: Codable, Equatable, Identifiable, Sendable {
        let sessionId: Int
        let vitals: ReplayCoverage
        let movement: ReplayCoverage
        var id: Int { sessionId }
    }
    struct Capabilities: Codable, Equatable, Sendable { let comparison: Bool; let stageReplay: Bool; let signalReplay: Bool }
    let version: String
    let parentDataset: Parent?
    let splitProtocol: SplitProtocol
    let coverage: [Coverage]
    let capabilities: Capabilities
    let limitations: [String]
    var supported: Bool {
        ["processed-dataset-manifest-v1", "waveform-dataset-manifest-v1"].contains(version)
            && splitProtocol.version == "chronological-whole-night-v1"
            && splitProtocol.grouping == "local_noon_connected_sessions"
    }
}
struct BiometricDataset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let side: Side
    let subjectId: String
    let contentHash: String
    let manifest: BiometricDatasetManifest
    let byteLength: Int
    let createdAtMs: Double
    let releasedAtMs: Double?
    let available: Bool
    var validIdentity: Bool { UUID(uuidString: id) != nil && BiometricBacktestInput.isHash(contentHash) }
}
struct BiometricDatasetPage: Codable, Sendable {
    struct Cursor: Codable, Equatable, Sendable { let createdAtMs: Double; let id: String }
    let items: [BiometricDataset]
    let nextCursor: Cursor?
}
struct BiometricDatasetSelection: Codable, Equatable, Sendable {
    let side: Side
    let subjectId: String
    let sessionIds: [Int]
    let referenceImportIds: [String]
    func validated() throws -> Self {
        guard (1...200).contains(subjectId.utf16.count), !subjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...60).contains(sessionIds.count), Set(sessionIds).count == sessionIds.count, sessionIds.allSatisfy({ $0 > 0 }),
              referenceImportIds.count <= 20, Set(referenceImportIds).count == referenceImportIds.count,
              referenceImportIds.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw BiometricBacktestInput.error("Choose a sleeper, 1–60 distinct sessions and up to 20 reference revisions.")
        }
        return self
    }
}
struct BiometricDatasetRequest: Codable, Equatable, Sendable {
    let side: Side
    let subjectId: String
    let sessionIds: [Int]
    let referenceImportIds: [String]
    let idempotencyKey: String
    init(selection: BiometricDatasetSelection, key: String = UUID().uuidString.lowercased()) {
        side = selection.side; subjectId = selection.subjectId
        sessionIds = selection.sessionIds.sorted(); referenceImportIds = selection.referenceImportIds.sorted(); idempotencyKey = key
    }
    var selection: BiometricDatasetSelection { .init(side: side, subjectId: subjectId, sessionIds: sessionIds, referenceImportIds: referenceImportIds) }
    func validated() throws -> Self {
        _ = try selection.validated()
        guard (1...200).contains(idempotencyKey.utf16.count) else { throw BiometricBacktestInput.error("The dataset request has no valid retry identity.") }
        return self
    }
    func matches(_ dataset: BiometricDataset) -> Bool {
        dataset.validIdentity && dataset.side == side && dataset.subjectId == subjectId
            && dataset.manifest.version == "processed-dataset-manifest-v1"
            && dataset.manifest.splitProtocol.assignments.flatMap(\.sessionIds).sorted() == sessionIds
    }
}
enum BiometricBacktestInput {
    static func error(_ message: String) -> ReferenceTextError { .init(message: message) }
    static func isHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func identifier(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw error("Invalid retained input identity. Reload this workspace.") }; return value
    }
    static func milliseconds(_ value: Double) throws -> String {
        guard value.isFinite, value >= 0, value <= 9007199254740991, value.rounded() == value else { throw error("Invalid page cursor. Reload this workspace.") }
        return String(format: "%.0f", value)
    }
}
