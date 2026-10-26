import Foundation

struct ReplayAdmission: Codable, Equatable, Sendable {
    let configured: Bool
    let qualificationId: String?
    let admitted: Bool
    let reasons: [String]
}
struct InspectedRawArtifact: Codable, Equatable, Sendable {
    let name: String
    let sha256: String
    let compressedBytes: Int
    let expandedBytes: Int
    enum CodingKeys: String, CodingKey { case name, sha256; case compressedBytes = "compressed_bytes", expandedBytes = "expanded_bytes" }
}
struct InspectedRawInventory: Codable, Equatable, Sendable {
    struct Channel: Codable, Equatable, Sendable {
        let samples: Int
        let lostMarkers: Int
        let truncatedTailBytes: Int
        enum CodingKeys: String, CodingKey { case samples; case lostMarkers = "lost_markers", truncatedTailBytes = "truncated_tail_bytes" }
    }
    struct Channels: Codable, Equatable, Sendable { let left1: Channel; let right1: Channel }
    let version: String
    let artifactSHA256: String
    let decodedRecords: Int
    let piezoRecords: Int
    let pumpRecords: Int
    let usableDualFrames: Int
    let emptyChannelFrames: Int
    let oversizeChannelFrames: Int
    let invalidTimestamps: Int
    let timestampReversals: Int
    let duplicateTimestamps: Int
    let firstEventMs: Double?
    let lastEventMs: Double?
    let channels: Channels
    let orderedWaveformAvailable: Bool
    let limitations: [String]
    var consistent: Bool {
        let counts = [decodedRecords, piezoRecords, pumpRecords, usableDualFrames, emptyChannelFrames, oversizeChannelFrames,
                      invalidTimestamps, timestampReversals, duplicateTimestamps, channels.left1.samples, channels.left1.lostMarkers,
                      channels.left1.truncatedTailBytes, channels.right1.samples, channels.right1.lostMarkers, channels.right1.truncatedTailBytes]
        guard counts.allSatisfy({ $0 >= 0 && $0 <= 9007199254740991 }),
              piezoRecords + pumpRecords <= decodedRecords,
              usableDualFrames + emptyChannelFrames + oversizeChannelFrames == piezoRecords,
              channels.left1.lostMarkers <= channels.left1.samples, channels.right1.lostMarkers <= channels.right1.samples,
              (firstEventMs == nil) == (lastEventMs == nil) else { return false }
        if let firstEventMs, let lastEventMs {
            guard (try? BiometricBacktestInput.milliseconds(firstEventMs)) != nil,
                  (try? BiometricBacktestInput.milliseconds(lastEventMs)) != nil, firstEventMs <= lastEventMs else { return false }
        }
        let ordered = usableDualFrames > 0 && invalidTimestamps == 0 && timestampReversals == 0 && oversizeChannelFrames == 0
        return orderedWaveformAvailable == ordered && (!ordered || firstEventMs != nil)
    }
    enum CodingKeys: String, CodingKey {
        case version, channels, limitations
        case artifactSHA256 = "artifact_sha256", decodedRecords = "decoded_records", piezoRecords = "piezo_records", pumpRecords = "pump_records"
        case usableDualFrames = "usable_dual_frames", emptyChannelFrames = "empty_channel_frames", oversizeChannelFrames = "oversize_channel_frames"
        case invalidTimestamps = "invalid_timestamps", timestampReversals = "timestamp_reversals", duplicateTimestamps = "duplicate_timestamps"
        case firstEventMs = "first_event_ms", lastEventMs = "last_event_ms", orderedWaveformAvailable = "ordered_waveform_available"
    }
}
struct InspectedRawSource: Codable, Equatable, Identifiable, Sendable {
    struct Inspection: Codable, Equatable, Sendable {
        let sourceName: String
        let retained: Bool
        let artifact: InspectedRawArtifact
        let inventory: InspectedRawInventory
        enum CodingKeys: String, CodingKey { case sourceName = "source_name"; case retained, artifact, inventory }
    }
    let id: String
    let inspection: Inspection
    let inspectedAtMs: Double
    let unavailableAtMs: Double?
    let availability: String
    var validIdentity: Bool {
        BiometricBacktestInput.isHash(id) && BiometricBacktestInput.isHash(inspection.artifact.sha256)
            && inspection.inventory.artifactSHA256 == inspection.artifact.sha256
            && inspection.artifact.name == inspection.artifact.sha256 + ".RAW.gz"
            && WaveformInput.validSourceName(inspection.sourceName) && !inspection.retained
            && inspection.inventory.consistent
            && (0...9007199254740991).contains(inspection.artifact.compressedBytes)
            && (0...9007199254740991).contains(inspection.artifact.expandedBytes)
            && (try? BiometricBacktestInput.milliseconds(inspectedAtMs)) != nil
            && (unavailableAtMs.map { (try? BiometricBacktestInput.milliseconds($0)) != nil } ?? true)
    }
    var selectable: Bool {
        validIdentity && availability == "requires_reverification" && unavailableAtMs == nil
            && inspection.inventory.version == "retained-raw-inventory-v1" && inspection.inventory.orderedWaveformAvailable
            && inspection.inventory.firstEventMs != nil && inspection.inventory.lastEventMs != nil
    }
}
struct InspectedRawPage: Codable, Sendable { let items: [InspectedRawSource]; let nextCursor: String? }
struct RawInspectionRequest: Encodable, Sendable {
    let afterName: String?
    enum CodingKeys: String, CodingKey { case afterName }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(afterName, forKey: .afterName)
    }
}
struct RawInspectionResult: Codable, Sendable {
    enum Status: String, Codable, Sendable { case inspected, sourceUnavailable = "source_unavailable", archiveUnavailable = "archive_unavailable", complete, deferred }
    let status: Status
    let nextCursor: String?
    let source: InspectedRawSource?
    func checked(after previous: String?) throws -> Self {
        switch status {
        case .inspected, .sourceUnavailable:
            guard let nextCursor, WaveformInput.validSourceName(nextCursor), previous.map({ nextCursor > $0 }) ?? true else { throw WaveformInput.failure("The archive scan did not return an advancing filename cursor.") }
            if status == .inspected {
                guard let source, source.validIdentity, source.inspection.sourceName == nextCursor else { throw WaveformInput.failure("The inspected source does not match the scan cursor.") }
            }
        case .complete, .archiveUnavailable:
            guard nextCursor == nil else { throw WaveformInput.failure("The archive scan completion has an unexpected cursor.") }
        case .deferred:
            guard nextCursor == previous else { throw WaveformInput.failure("The deferred scan changed its cursor.") }
        }
        return self
    }
}
struct WaveformDatasetRequest: Codable, Equatable, Hashable, Identifiable, Sendable {
    struct Cohort: Codable, Equatable, Hashable, Sendable { let cohortId: String; let sourceIds: [String] }
    let parentDatasetId: String
    let expectedContentHash: String
    let cohorts: [Cohort]
    let idempotencyKey: String
    var id: String { idempotencyKey }
    func validated() throws -> Self {
        _ = try BiometricBacktestInput.identifier(parentDatasetId)
        guard BiometricBacktestInput.isHash(expectedContentHash), (1...60).contains(cohorts.count),
              Set(cohorts.map(\.cohortId)).count == cohorts.count, (1...200).contains(idempotencyKey.utf16.count),
              cohorts.allSatisfy({ (1...200).contains($0.cohortId.utf16.count) && (1...64).contains($0.sourceIds.count)
                  && Set($0.sourceIds).count == $0.sourceIds.count && $0.sourceIds.allSatisfy(BiometricBacktestInput.isHash) }) else {
            throw WaveformInput.failure("Select 1–64 distinct inspected archives for every frozen night, with an unchanged parent and retry identity.")
        }
        return self
    }
    func matches(_ result: BiometricDataset, side: Side) -> Bool {
        result.validIdentity && result.side == side && result.manifest.version == "waveform-dataset-manifest-v1"
            && result.manifest.parentDataset?.id == parentDatasetId && result.manifest.parentDataset?.contentHash == expectedContentHash
            && Set(result.manifest.splitProtocol.assignments.map(\.cohortId)) == Set(cohorts.map(\.cohortId))
    }
}
struct WaveformDatasetResponse: Codable, Sendable {
    enum Status: String, Codable, Sendable { case published, deferred }
    let status: Status
    let dataset: BiometricDataset?
}
enum WaveformInput {
    static func failure(_ message: String) -> ReferenceTextError { .init(message: message) }
    static func validSourceName(_ name: String) -> Bool {
        name.utf16.count <= 255 && name.range(of: "^[A-Za-z0-9_.-]+\\.RAW\\.gz$", options: .regularExpression) == name.startIndex..<name.endIndex
    }
}
