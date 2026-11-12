import CryptoKit
import Foundation
@testable import FreeSleepKit

@MainActor final class PersonalReportTestState {
    let access: PersonalHealthAccess
    var current: PersonalHealthAccess?
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var unlocked = true
    var permitted = true
    var personal = true
    var healthCurrent = true
    var health: PersonalReportEvidence?
    init(_ access: PersonalHealthAccess) {
        self.access = access; current = access
        health = PersonalReportFixture.evidence(identity: access.identity, at: now)
    }
    func revised(credential: String = String(repeating: "a", count: 64), assignment: Int = 1) throws -> PersonalHealthAccess {
        try .init(identity: access.identity, connectionID: access.connectionID, credentialRevision: credential,
                  sessionRevision: 1, householdRevision: 1, assignmentRevision: assignment)
    }
}

@MainActor final class PersonalReportTestKeys: PersonalProviderKeys {
    var values: [IntelligenceProvider: String] = [:]
    func read(_ provider: IntelligenceProvider) throws -> String { values[provider] ?? "" }
    func save(_ value: String, for provider: IntelligenceProvider) throws { values[provider] = value }
    func remove(_ provider: IntelligenceProvider) throws { values[provider] = nil }
}

actor PersonalReportTestTransport {
    private(set) var requests: [ModelRequest] = []
    private(set) var catalogRequests: [(provider: IntelligenceProvider, key: String, address: String)] = []
    private var blocked = false
    private var fails = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false
    func hold() { blocked = true }
    func fail() { fails = true }
    func generate(_ request: ModelRequest) async throws -> ModelReply {
        requests.append(request)
        if blocked { await withCheckedContinuation { continuation = $0 } }
        wasCancelled = Task.isCancelled
        try Task.checkCancellation()
        if fails { throw URLError(.notConnectedToInternet) }
        return .init(text: "### Recorded observations\nA fixture interpretation [health.recent].",
                     model: request.model, inputTokens: 100, outputTokens: 20)
    }
    func models(_ provider: IntelligenceProvider, key: String, address: String) async throws -> [String] {
        catalogRequests.append((provider, key, address))
        if blocked { await withCheckedContinuation { continuation = $0 } }
        wasCancelled = Task.isCancelled
        try Task.checkCancellation()
        if fails { throw URLError(.notConnectedToInternet) }
        return ["account-model", "bad model\n", ""]
    }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil; blocked = false }
}

@MainActor final class PersonalReportFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let state: PersonalReportTestState
    let snapshots: PrivateSnapshotStore
    let store: PersonalReportStore
    let keys = PersonalReportTestKeys()
    let transport = PersonalReportTestTransport()
    let model: PersonalReportWorkspace
    init(snapshots supplied: PrivateSnapshotStore? = nil) throws {
        let access = try PersonalHealthAccess(identity: Self.identity(), connectionID: UUID(),
            credentialRevision: String(repeating: "a", count: 64), sessionRevision: 1, householdRevision: 1, assignmentRevision: 1)
        let state = PersonalReportTestState(access); self.state = state
        let key = SymmetricKey(size: .bits256)
        snapshots = supplied ?? .init(directory: directory, namespace: "personal-report-test", encryptionKey: { key })
        store = .init(snapshots: snapshots, now: { state.now })
        let transport = transport
        model = .init(access: access, displayName: "Example sleeper", currentAccess: { state.current },
            requestPermitted: { state.permitted }, store: store, keys: keys, evidence: { _ in state.health },
            evidenceCurrent: { state.healthCurrent && state.health == $0 }, protectedData: { state.unlocked },
            allowedMode: { state.personal }, generateModel: { try await transport.generate($0) },
            listModels: { try await transport.models($0, key: $1, address: $2) }, now: { state.now })
    }
    func cloud(limit: Int = 100) {
        model.restore()
        model.configure(.init(provider: .openai, model: "test-model", localAddress: "", monthlyLimit: limit))
        model.saveKey("fixture-personal-key")
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    static func identity() -> PersonalHealthIdentity {
        .init(podID: UUID(), householdID: UUID(), accountID: UUID(), sleeperID: UUID())
    }
    static func evidence(identity: PersonalHealthIdentity, at instant: Date) -> PersonalReportEvidence {
        .init(identity: identity, healthRevision: UUID(), sourceID: "my-source", sourceName: "My Watch", importedAt: instant,
              facts: [.init(id: "health.recent", text: "An account-only observation: one recorded night, other days unknown.")], comparison: nil)
    }
}
