#if DEBUG
import Foundation
import FreeSleepKit

/// Synthetic learning files use the frozen Core contract, never credentials or a live Pod.
@MainActor enum PersonalLearningPreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--learning-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let server = try PersonalLearningPreviewServer(mode: arguments[index + 1])
            let account = server.account
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://learning-preview.invalid")!,
                deviceSecret: String(repeating: "A", count: 43), identity: account)
            let vault = PersonalHistoryPreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "personal-learning-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, learningClient: { _ in server },
                capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
}

private actor PersonalLearningPreviewServer: PersonalLearningTransport, HouseholdTransport {
    nonisolated let account: HouseholdSession
    private let mode: String
    private let ordinary: PersonalHistoryPreviewServer
    private let fixture: [String: Any]
    private var removalResponse: PersonalLearningRemovalResponse?
    init(mode: String) throws {
        self.mode = mode
        guard let url = Bundle.main.url(forResource: "personal-learning-v1", withExtension: "json"),
              let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var session = fixture["session"] as? [String: Any],
              var capabilities = session["capabilities"] as? [String: Any] else { throw HouseholdFailure.invalid }
        self.fixture = fixture
        capabilities["personalLearningArchive"] = mode != "disabled"
        capabilities["personalLearningRemoval"] = mode != "removal-readonly"
        session["capabilities"] = capabilities
        account = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: session))
        ordinary = PersonalHistoryPreviewServer(account: account, mode: "ready")
    }
    func session() async throws -> HouseholdSession { account }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        try await ordinary.send(path: path, method: method, token: token, body: body)
    }
    func archives(before: String?, limit: Int) async throws -> PersonalLearningArchivePage {
        if mode == "error" { throw HouseholdFailure.uncertain }
        var value = try object("archives")
        if mode == "empty" { value["archives"] = [] }
        return try .decodeExact(JSONSerialization.data(withJSONObject: value))
    }
    func records(archiveId: String, after: Int, limit: Int) async throws -> PersonalLearningRecordPage {
        let page = try PersonalLearningRecordPage.decodeExact(JSONSerialization.data(withJSONObject: object("records")))
        return removalResponse?.receipt.map { page.removingPayload($0.recordId) } ?? page
    }
    func detail(recordId: String) async throws -> PersonalLearningDetail {
        let detail = try PersonalLearningDetail.decodeExact(JSONSerialization.data(withJSONObject: object("detail")))
        return removalResponse?.receipt?.recordId == recordId ? detail.removingPayload : detail
    }
    func remove(_ request: PersonalLearningRemovalRequest) async throws -> PersonalLearningRemovalResponse {
        try request.validate(for: account)
        guard account.capabilities.personalLearningRemoval == true else { throw HouseholdFailure.unavailable }
        if mode == "removal-revoked" { throw HouseholdFailure.authentication }
        if mode == "removal-busy" { try await Task.sleep(for: .seconds(8)) }
        let detail = try PersonalLearningDetail.decodeExact(JSONSerialization.data(withJSONObject: object("detail")))
        let response = PersonalLearningRemovalResponse(version: 1, generatedAt: detail.generatedAt, scope: detail.scope,
            interpretation: "archived_copy_removal_not_source_deletion", receipt: mode == "removal-pending" ? nil : .init(
                requestId: request.requestId, recordId: request.recordId, archiveId: request.archiveId,
                payloadHash: request.expectedPayloadHash, removedAt: detail.generatedAt, outcome: "content_removed"))
        removalResponse = response
        if mode == "removal-uncertain" { throw HouseholdFailure.uncertain }
        return response
    }
    func removalReceipt(requestId: String) async throws -> PersonalLearningRemovalResponse {
        guard let removalResponse else { throw HouseholdFailure.invalid }
        return removalResponse
    }
    private func object(_ name: String) throws -> [String: Any] {
        guard let value = fixture[name] as? [String: Any] else { throw HouseholdFailure.invalid }
        return value
    }
}
#endif
