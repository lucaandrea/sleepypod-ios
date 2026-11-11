import Foundation

/// Keep the native projection as narrow as the person-owned API, including nested habit fields.
enum PersonalJournalDecoding {
    static func patterns(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        try keys(object, ["version", "generatedAt", "scope", "interpretation", "query", "source", "minimumDatesPerGroup", "cohorts", "note"])
        try keys(object["scope"], ["podId", "householdId", "accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"])
        try keys(object["query"], ["from", "through"])
        guard let cohorts = object["cohorts"] as? [[String: Any]], cohorts.count <= 90 else { throw HouseholdFailure.invalid }
        for cohort in cohorts {
            try keys(cohort, ["timeZone", "dates", "comparisons"])
            guard let comparisons = cohort["comparisons"] as? [[String: Any]], (5...8).contains(comparisons.count) else { throw HouseholdFailure.invalid }
            for comparison in comparisons {
                try keys(comparison, ["id", "label", "withLabel", "withoutLabel", "withCount", "withoutCount", "excludedCount", "withWarmCount", "withoutWarmCount", "warmRateDifferencePoints", "quantityThreshold"])
            }
        }
    }
    static func check(_ data: Data, receipt: Bool) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        let common: Set<String> = ["version", "generatedAt", "scope", "interpretation"]
        try keys(object["scope"], ["podId", "householdId", "accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"])
        if receipt {
            try keys(object, common.union(["receipt"]))
            if !(object["receipt"] is NSNull) {
                try keys(object["receipt"], ["requestId", "date", "revision", "timeZone", "savedAt", "outcome"])
            }
        } else {
            try keys(object, common.union(["currentTimeZone", "query", "entries"]))
            try keys(object["query"], ["date"])
            guard let entries = object["entries"] as? [[String: Any]], entries.count == 1 else { throw HouseholdFailure.invalid }
            for entry in entries {
                try keys(entry, ["date", "revision", "timeZone", "record"])
                if !(entry["record"] is NSNull) {
                    guard let record = entry["record"] as? [String: Any] else { throw HouseholdFailure.invalid }
                    try keys(record, ["date", "timeZone", "createdAt", "updatedAt", "fields"])
                    guard let fields = record["fields"] as? [String: Any] else { throw HouseholdFailure.invalid }
                    try keys(fields, ["restfulness", "comfort", "notes", "caffeine", "alcohol", "exercise"], optional: ["context"])
                    if let context = fields["context"] {
                        try keys(context, ["version", "caffeine", "alcohol", "exercise", "stress"], optional: ["bedtimeAt", "lastMealAt"])
                        guard let context = context as? [String: Any] else { throw HouseholdFailure.invalid }
                        for habit in ["caffeine", "alcohol", "exercise"] {
                            try keys(context[habit], ["status", "unit"], optional: ["lastAt", "amount"])
                        }
                    }
                }
            }
        }
    }
    private static func keys(_ value: Any?, _ required: Set<String>, optional: Set<String> = []) throws {
        guard let object = value as? [String: Any], required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else { throw HouseholdFailure.invalid }
    }
}
