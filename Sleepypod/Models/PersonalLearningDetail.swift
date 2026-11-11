import Foundation
import CryptoKit

struct PersonalLearningDetail: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let interpretation: String
    let recordId: String
    let archiveId: String
    let sourceTable: String
    let sourceSide: Side
    let kind: String
    let attribution: String
    let activation: String
    let payloadHash: String
    let encoding: String
    let payload: String?
    let redacted: Bool
    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalLearningDecoding.check(data, shape: .detail)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession, archive: PersonalLearningArchive, record: PersonalLearningRecord) throws {
        try PersonalLearningContract.envelope(version, generatedAt: generatedAt, interpretation: interpretation, scope: scope, session: session)
        guard recordId == record.id, archiveId == archive.id, sourceTable == record.sourceTable, sourceSide == record.sourceSide,
              kind == record.kind, redacted == record.redacted, redacted == (payload == nil),
              attribution == PersonalLearningContract.attribution, activation == PersonalLearningContract.activation,
              PersonalLearningContract.digest(payloadHash), encoding == "sqlite_row_json_text" else { throw HouseholdFailure.invalid }
        if let payload {
            let data = Data(payload.utf8)
            guard data.count == record.payloadBytes, data.count <= PersonalLearningContract.recordBytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == payloadHash else { throw HouseholdFailure.invalid }
        }
    }
}
