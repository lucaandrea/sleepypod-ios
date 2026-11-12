import Foundation

/// An explicit display-only export. It contains neither raw Health samples nor provider credentials.
enum MorningReportTransfer {
    enum Failure: Error, Equatable { case invalidReport, tooLarge }
    enum Relationship { case same, localHasMoreAnswers, sharedHasMoreAnswers, different }
    static let maximumBytes = 384 * 1024

    /// Answers may extend a shared prefix. Original evidence and existing answers must match exactly.
    static func relationship(local: Data, shared: Data) throws -> Relationship {
        func report(_ data: Data) throws -> [String: Any] {
            guard data.count <= maximumBytes, let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var value = envelope["report"] as? [String: Any] else { throw Failure.invalidReport }
            if let id = value["id"] as? String { value["id"] = id.lowercased() }
            value["followUps"] = (value["followUps"] as? [[String: Any]] ?? []).map { answer in
                var answer = answer
                if let id = answer["id"] as? String { answer["id"] = id.lowercased() }
                return answer
            }
            return value
        }
        var local = try report(local), shared = try report(shared)
        let localAnswers = local.removeValue(forKey: "followUps") as? [[String: Any]] ?? []
        let sharedAnswers = shared.removeValue(forKey: "followUps") as? [[String: Any]] ?? []
        guard NSDictionary(dictionary: local) == NSDictionary(dictionary: shared),
              zip(localAnswers, sharedAnswers).allSatisfy({ NSDictionary(dictionary: $0) == NSDictionary(dictionary: $1) }) else { return .different }
        if localAnswers.count == sharedAnswers.count { return .same }
        return localAnswers.count > sharedAnswers.count ? .localHasMoreAnswers : .sharedHasMoreAnswers
    }

    static func document(_ report: PersonalSleepReport, now: Date = .now) throws -> Data {
        try validate(report, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(milliseconds(date))
        }
        let data = try encoder.encode(Document(report: TransferReport(report)))
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        return data
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard value.isFinite, value >= 0, value <= 253_402_300_799_999 else { throw Failure.invalidReport }
        return Int64(value)
    }

    private static func bounded(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf16.count <= maximum
    }

    private static func validate(_ report: PersonalSleepReport, now: Date) throws {
        let current = try milliseconds(now), created = try milliseconds(report.createdAt)
        let answers = report.followUps ?? []
        guard created <= current, bounded(report.model, maximum: 128), bounded(report.source, maximum: 256),
              bounded(report.text, maximum: 60_000), report.facts.count <= 80,
              Set(report.facts.map(\.id)).count == report.facts.count,
              report.facts.allSatisfy({ fact in
                  fact.id.range(of: "^[a-z][a-z0-9_.-]{0,99}$", options: .regularExpression) != nil
                      && bounded(fact.text, maximum: 8000)
              }), report.inputTokens.map({ $0 >= 0 }) ?? true, report.outputTokens.map({ $0 >= 0 }) ?? true,
              answers.count <= 10, Set([report.id] + answers.map(\.id)).count == answers.count + 1 else {
            throw Failure.invalidReport
        }
        for answer in answers {
            let answered = try milliseconds(answer.createdAt)
            guard answered >= created, answered <= current, bounded(answer.question, maximum: 1000),
                  bounded(answer.text, maximum: 60_000), bounded(answer.model, maximum: 128),
                  answer.inputTokens.map({ $0 >= 0 }) ?? true, answer.outputTokens.map({ $0 >= 0 }) ?? true else {
                throw Failure.invalidReport
            }
        }
    }

    private struct Document: Encodable { let version = 1; let report: TransferReport }
    private struct TransferReport: Encodable {
        let id: UUID
        let createdAt: Date
        let provider: IntelligenceProvider
        let model: String
        let source: String
        let facts: [SleepFact]
        let text: String
        let inputTokens: Int?
        let outputTokens: Int?
        let comparison: TransferComparison?
        let followUps: [PersonalReportFollowUp]?

        init(_ original: PersonalSleepReport) {
            id = original.id; createdAt = original.createdAt; provider = original.provider
            model = original.model; source = original.source; facts = original.facts; text = original.text
            inputTokens = original.inputTokens; outputTokens = original.outputTokens
            comparison = original.comparison.map(TransferComparison.init); followUps = original.followUps
        }
    }
    private struct TransferComparison: Encodable {
        let metric = "recorded_sleep_minutes"
        let sourceID: String
        let sourceName: String
        let timeZone: String
        let importedAt: Date
        let asOf: Date
        let omittedRecords: Int
        let days: [TransferDay]

        init(_ original: ReportSleepComparison) {
            sourceID = original.sourceID; sourceName = original.sourceName; timeZone = original.timeZone
            importedAt = original.importedAt; asOf = original.asOf
            omittedRecords = original.omittedRecords; days = original.days.map(TransferDay.init)
        }
    }
    private struct TransferDay: Encodable {
        let original: ReportSleepComparison.Day
        init(_ original: ReportSleepComparison.Day) { self.original = original }
        private enum CodingKeys: String, CodingKey { case start, end, minutes }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(original.start, forKey: .start)
            try container.encode(original.end, forKey: .end)
            if let minutes = original.minutes { try container.encode(minutes, forKey: .minutes) }
            else { try container.encodeNil(forKey: .minutes) }
        }
    }
}
