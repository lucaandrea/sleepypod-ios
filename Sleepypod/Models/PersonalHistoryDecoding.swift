import Foundation

/// Reject broader payloads before decoding so a personal screen cannot silently accept another source or projection.
enum PersonalHistoryDecoding {
    static func envelope(version: Int, attribution: Int, generatedAt: Int64, source: String, interpretation: String) throws {
        guard version == 1, HouseholdValidation.revision(attribution), PersonalHistoryQuery.validTime(generatedAt),
              source == "pod", interpretation == "recordings_not_confirmed_sleep" else { throw HouseholdFailure.invalid }
    }
    static func check(_ data: Data, detail: Bool) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        let common: Set<String> = ["version", "scope", "attributionRevision", "generatedAt", "source", "interpretation"]
        try keys(object, common.union(detail ? ["record"] : ["query", "intervalSelection", "records", "nextCursor"]))
        try keys(object["scope"], ["podId", "householdId", "accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"])
        if detail { try record(object["record"]) }
        else {
            try keys(object["query"], ["startsAt", "endsAt", "kind", "limit"])
            guard let records = object["records"] as? [[String: Any]], records.count <= 100 else { throw HouseholdFailure.invalid }
            for value in records { try record(value) }
        }
    }
    private static func record(_ value: Any?) throws {
        try keys(value, ["id", "sleeperId", "startsAt", "endsAt", "recordedSide", "payload", "attribution"])
        guard let object = value as? [String: Any], let payload = object["payload"] as? [String: Any] else { throw HouseholdFailure.invalid }
        try keys(object["attribution"], ["epochId", "mode", "basis", "identity"])
        switch payload["kind"] as? String {
        case "presence": try keys(payload, ["kind", "reportedPresenceSeconds", "exits", "interpretation"])
        case "vitals": try keys(payload, ["kind", "heartRateBpm", "breathingRatePerMinute", "hrvMs", "hrvMetric"])
        case "movement": try keys(payload, ["kind", "total", "interpretation"])
        default: throw HouseholdFailure.invalid
        }
    }
    private static func keys(_ value: Any?, _ expected: Set<String>) throws {
        guard let object = value as? [String: Any], Set(object.keys) == expected else { throw HouseholdFailure.invalid }
    }
}
