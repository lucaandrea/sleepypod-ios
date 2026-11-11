#if DEBUG
import Foundation
import FreeSleepKit

/// Test-only synthetic personal account; no owner credential, Health import or live Pod is used.
@MainActor enum PersonalJournalPreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--personal-journal-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let server = try PersonalJournalPreviewServer(mode: arguments[index + 1])
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://journal-preview.invalid")!,
                deviceSecret: String(repeating: "A", count: 43), identity: server.account)
            let vault = PersonalHistoryPreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "personal-journal-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, journalClient: { _ in server },
                capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
}

private actor PersonalJournalPreviewServer: PersonalJournalTransport, HouseholdTransport {
    nonisolated let account: HouseholdSession
    private let mode: String
    private let ordinary: PersonalHistoryPreviewServer
    private let example: PersonalJournalPage
    private var seeded = false
    private var entries: [String: PersonalJournalSelection] = [:]
    private var receipts: [String: PersonalJournalReceipt] = [:]
    init(mode: String) throws {
        self.mode = mode
        guard let url = Bundle.main.url(forResource: "personal-journal-v1", withExtension: "json"),
              let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var session = fixture["session"] as? [String: Any],
              var capabilities = session["capabilities"] as? [String: Any], let page = fixture["page"] else { throw HouseholdFailure.invalid }
        capabilities["personalJournal"] = mode != "disabled"; session["capabilities"] = capabilities
        capabilities["personalJournalPatterns"] = mode.hasPrefix("patterns-"); session["capabilities"] = capabilities
        account = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: session))
        example = try .decodeExact(JSONSerialization.data(withJSONObject: page))
        ordinary = PersonalHistoryPreviewServer(account: account, mode: "ready")
    }
    func session() async throws -> HouseholdSession { account }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        try await ordinary.send(path: path, method: method, token: token, body: body)
    }
    func read(date: String) async throws -> PersonalJournalPage {
        if mode == "error" { throw HouseholdFailure.uncertain }
        if !seeded, mode != "empty", let record = example.entries.first?.record {
            seeded = true
            entries[date] = .init(date: date, revision: UUID().uuidString.lowercased(), timeZone: record.timeZone,
                record: .init(date: date, timeZone: record.timeZone, createdAt: timestamp, updatedAt: timestamp, fields: record.fields))
        }
        return .init(version: 1, generatedAt: timestamp, scope: example.scope, interpretation: example.interpretation,
                     currentTimeZone: example.currentTimeZone, query: .init(date: date),
                     entries: [entries[date] ?? .init(date: date, revision: nil, timeZone: nil, record: nil)])
    }
    func write(_ input: PersonalJournalWrite) async throws -> PersonalJournalResult {
        guard input.expectedRevision == entries[input.date]?.revision else { throw HouseholdFailure.conflict }
        let receipt = PersonalJournalReceipt(requestId: input.requestId, date: input.date, revision: UUID().uuidString.lowercased(),
            timeZone: input.expectedTimeZone, savedAt: timestamp, outcome: input.fields == nil ? "deleted" : "saved")
        receipts[input.requestId] = receipt
        entries[input.date] = .init(date: input.date, revision: receipt.revision, timeZone: receipt.timeZone, record: input.fields.map {
            .init(date: input.date, timeZone: receipt.timeZone, createdAt: receipt.savedAt, updatedAt: receipt.savedAt, fields: $0)
        })
        if mode == "uncertain" { throw HouseholdFailure.uncertain }
        return result(receipt)
    }
    func receipt(requestId: String) async throws -> PersonalJournalResult { result(receipts[requestId]) }
    func patterns(range: PersonalJournalRange) async throws -> PersonalJournalPatterns {
        if mode == "patterns-error" { throw HouseholdFailure.uncertain }
        if mode == "patterns-loading" { try await Task.sleep(for: .seconds(8)) }
        guard let url = Bundle.main.url(forResource: "personal-journal-patterns-v1", withExtension: "json"),
              let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw HouseholdFailure.invalid }
        let key = mode == "patterns-empty" ? "empty" : mode == "patterns-insufficient" ? "insufficient" : "ready"
        guard var response = fixture[key] as? [String: Any] else { throw HouseholdFailure.invalid }
        response["query"] = ["from": range.from, "through": range.through]
        return try .decodeExact(JSONSerialization.data(withJSONObject: response))
    }
    private var timestamp: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    private func result(_ receipt: PersonalJournalReceipt?) -> PersonalJournalResult {
        .init(version: 1, generatedAt: timestamp, scope: example.scope, interpretation: example.interpretation, receipt: receipt)
    }
}
#endif
