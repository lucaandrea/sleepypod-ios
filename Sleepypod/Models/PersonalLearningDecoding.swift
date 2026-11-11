import Foundation

/// Reject broader projections before decoding; original source JSON remains an uninterpreted string.
enum PersonalLearningDecoding {
    enum Shape { case archives, records, detail }
    static func check(_ data: Data, shape: Shape) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        let common: Set<String> = ["version", "generatedAt", "scope", "interpretation"]
        try keys(object["scope"], ["podId", "householdId", "accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"])
        switch shape {
        case .archives:
            try keys(object, common.union(["query", "archives", "nextCursor"]))
            try keys(object["query"], ["before", "limit"])
            guard let archives = object["archives"] as? [[String: Any]], archives.count <= 50 else { throw HouseholdFailure.invalid }
            for archive in archives {
                try keys(archive, ["archiveId", "capturedAt", "sourceSide", "timeZone", "recordCount", "payloadBytes", "contentHash", "attribution", "activation"])
            }
        case .records:
            try keys(object, common.union(["query", "archiveId", "contentHash", "records", "nextOrdinal"]))
            try keys(object["query"], ["archiveId", "after", "limit"])
            guard let records = object["records"] as? [[String: Any]], records.count <= 50 else { throw HouseholdFailure.invalid }
            for record in records {
                try keys(record, ["recordId", "ordinal", "sourceTable", "sourceSide", "kind", "payloadBytes", "redacted"], optional: ["recordedDate"])
            }
        case .detail:
            try keys(object, common.union(["recordId", "archiveId", "sourceTable", "sourceSide", "kind", "attribution", "activation", "payloadHash", "encoding", "payload", "redacted"]))
        }
    }
    private static func keys(_ value: Any?, _ required: Set<String>, optional: Set<String> = []) throws {
        guard let object = value as? [String: Any], required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else { throw HouseholdFailure.invalid }
    }
}
