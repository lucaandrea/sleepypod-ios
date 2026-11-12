#if DEBUG
import Foundation
import FreeSleepKit

/// Synthetic account used only by explicit simulator review; no real Pod or home actions.
@MainActor enum PersonalQuietPreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--personal-quiet-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let server = try PersonalQuietPreviewServer(mode: arguments[index + 1])
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://quiet-preview.invalid")!,
                deviceSecret: String(repeating: "A", count: 43), identity: server.account)
            let vault = PersonalHistoryPreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "personal-quiet-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, quietClient: { _ in server },
                capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
}

actor PersonalQuietPreviewServer: PersonalQuietTransport, HouseholdTransport {
    nonisolated let account: HouseholdSession
    private let ordinary: PersonalHistoryPreviewServer
    private let scope: PersonalHistoryScope
    private let mode: String
    private var revision: String?
    private var ownerEnd: Int64?
    private let partnerEnd: Int64?
    private var receipts: [String: PersonalQuietReceipt] = [:]
    private(set) var writeCount = 0
    init(mode: String) throws {
        self.mode = mode
        guard let url = Bundle.main.url(forResource: "personal-quiet-v1", withExtension: "json"),
              let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var session = fixture["session"] as? [String: Any], var capabilities = session["capabilities"] as? [String: Any],
              let idle = fixture["idle"] else { throw HouseholdFailure.invalid }
        capabilities["householdQuiet"] = mode != "disabled"
        capabilities["arrangementMaintenance"] = false
        session["capabilities"] = capabilities
        account = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: session))
        scope = try PersonalQuietPage.decodeExact(JSONSerialization.data(withJSONObject: idle)).scope
        ordinary = PersonalHistoryPreviewServer(account: account, mode: "ready")
        partnerEnd = mode == "idle" ? nil : Int64(Date().timeIntervalSince1970 * 1_000) + 7_200_000
    }
    func session() async throws -> HouseholdSession { account }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        try await ordinary.send(path: path, method: method, token: token, body: body)
    }
    func read() async throws -> PersonalQuietPage {
        if mode == "error" { throw HouseholdFailure.uncertain }
        if mode == "loading" { try await Task.sleep(for: .seconds(60)) }
        let clock = timestamp
        let own = ownerEnd.flatMap { $0 > clock ? $0 : nil }
        let shared = [own, partnerEnd].compactMap { $0 }.filter { $0 > clock }.max()
        return .init(version: 1, generatedAt: clock, scope: scope, mine: .init(revision: revision, until: own),
            shared: .init(paused: shared != nil, until: shared))
    }
    func write(_ input: PersonalQuietWrite) async throws -> PersonalQuietResult {
        try input.validate()
        guard input.expectedRevision == revision else { throw HouseholdFailure.conflict }
        writeCount += 1; revision = UUID().uuidString.lowercased(); ownerEnd = input.until
        let receipt = PersonalQuietReceipt(requestId: input.requestId, revision: revision!, savedAt: timestamp, until: input.until)
        receipts[input.requestId] = receipt
        if mode == "uncertain" { throw HouseholdFailure.uncertain }
        return result(receipt)
    }
    func receipt(requestId: String) async throws -> PersonalQuietResult { result(receipts[requestId]) }
    private var timestamp: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    private func result(_ receipt: PersonalQuietReceipt?) -> PersonalQuietResult {
        .init(version: 1, generatedAt: timestamp, scope: scope, receipt: receipt)
    }
}
#endif
