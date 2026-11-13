import Foundation

struct PersonalLearningRemovalRequest: Codable, Equatable, Sendable {
    let version: Int
    let requestId: String
    let expectedSessionRevision: Int
    let expectedAssignmentRevision: Int
    let recordId: String
    let archiveId: String
    let expectedPayloadHash: String
    let confirmRemoveArchivedCopy: Bool

    func validate(for session: HouseholdSession) throws {
        guard version == 1, [requestId, recordId, archiveId].allSatisfy(HouseholdValidation.identifier),
              expectedSessionRevision == session.sessionRevision,
              expectedAssignmentRevision == session.assignmentRevision,
              PersonalLearningContract.digest(expectedPayloadHash), confirmRemoveArchivedCopy else { throw HouseholdFailure.invalid }
    }
}

struct PersonalLearningRemovalReceipt: Codable, Equatable, Sendable {
    let requestId: String
    let recordId: String
    let archiveId: String
    let payloadHash: String
    let removedAt: Int64
    let outcome: String
}

struct PersonalLearningRemovalResponse: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let interpretation: String
    let receipt: PersonalLearningRemovalReceipt?

    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalLearningDecoding.check(data, shape: .removal)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession, request: PersonalLearningRemovalRequest, capturedAt: Int64) throws {
        try request.validate(for: session)
        try scope.validate(for: session)
        guard version == 1, PersonalLearningContract.instant(generatedAt), generatedAt >= capturedAt,
              interpretation == "archived_copy_removal_not_source_deletion" else { throw HouseholdFailure.invalid }
        if let receipt {
            guard receipt.requestId == request.requestId, receipt.recordId == request.recordId,
                  receipt.archiveId == request.archiveId, receipt.payloadHash == request.expectedPayloadHash,
                  receipt.outcome == "content_removed", PersonalLearningContract.instant(receipt.removedAt),
                  receipt.removedAt >= capturedAt, receipt.removedAt <= generatedAt else { throw HouseholdFailure.invalid }
        }
    }
}

/// The pending confirmation keeps metadata only, never another copy of the private body.
struct PersonalLearningRemovalProgress: Equatable {
    enum Phase { case review, uncertain, removed }
    let request: PersonalLearningRemovalRequest
    let title: String
    let capturedAt: Int64
    let redactedDetail: PersonalLearningDetail
    var phase: Phase = .review
    var receipt: PersonalLearningRemovalReceipt?
}

extension PersonalLearningDetail {
    var removingPayload: Self {
        .init(version: version, generatedAt: generatedAt, scope: scope, interpretation: interpretation,
              recordId: recordId, archiveId: archiveId, sourceTable: sourceTable, sourceSide: sourceSide,
              kind: kind, attribution: attribution, activation: activation, payloadHash: payloadHash,
              encoding: encoding, payload: nil, redacted: true)
    }
}

extension PersonalLearningRecordPage {
    func removingPayload(_ identifier: String) -> Self {
        .init(version: version, generatedAt: generatedAt, scope: scope, interpretation: interpretation, query: query,
              archiveId: archiveId, contentHash: contentHash, records: records.map { record in
            guard record.id == identifier else { return record }
            return .init(recordId: record.recordId, ordinal: record.ordinal, sourceTable: record.sourceTable,
                         sourceSide: record.sourceSide, kind: record.kind, payloadBytes: record.payloadBytes,
                         redacted: true, recordedDate: record.recordedDate)
        }, nextOrdinal: nextOrdinal)
    }
}
