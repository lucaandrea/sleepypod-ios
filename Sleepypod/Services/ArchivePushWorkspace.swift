import Foundation
import Observation

@MainActor @Observable final class ArchivePushWorkspace {
    private let client: any ArchivePushClient
    var draft: ArchivePushDraft?
    private(set) var snapshot: ArchivePushSnapshot?
    private(set) var error: String?
    private(set) var receipt: String?
    private(set) var testReceipt: ArchivePushTestReceipt?
    private var testedConfiguration: ArchivePushConfiguration?
    private(set) var loading = false
    private(set) var operation: String?
    private(set) var mustReload = false
    var busy: Bool { operation != nil }
    var dirty: Bool { guard let draft, let snapshot else { return false }; return draft != ArchivePushDraft(snapshot.config) }
    var currentTest: ArchivePushTestReceipt? {
        guard let draft, let testedConfiguration, draft == ArchivePushDraft(testedConfiguration) else { return nil }
        return testReceipt
    }
    init(client: any ArchivePushClient) { self.client = client }
    func refresh(discardDraft: Bool = false) async {
        guard !loading, !busy, !dirty || discardDraft else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await client.settings()
            guard !Task.isCancelled else { return }
            snapshot = value; draft = .init(value.config); error = nil; mustReload = false
            if discardDraft { receipt = nil; clearTest() }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func save() async {
        guard !busy, !loading, !mustReload, dirty, let snapshot, let proposed = draft?.configuration else { return }
        operation = "Saving…"; error = nil; receipt = nil; clearTest()
        var sent = false
        defer { operation = nil }
        do {
            guard try await matches(snapshot.config) else { return }
            try Task.checkCancellation()
            sent = true
            try await client.save(proposed)
            receipt = "Archive configuration saved. Nightly delivery runs on the Pod."
            try await readBack()
        } catch { recordFailure(error, sent: sent) }
    }
    func generateKey() async {
        guard !busy, !loading, !mustReload, !dirty, let snapshot, snapshot.publicKey == nil else { return }
        operation = "Generating key…"; error = nil; receipt = nil; clearTest()
        var sent = false
        defer { operation = nil }
        do {
            guard try await matches(snapshot.config) else { return }
            try Task.checkCancellation()
            sent = true
            let result = try await client.generateKey()
            receipt = result.generated ? "SSH public key generated on the Pod." : "The Pod’s existing SSH public key is ready."
            try await readBack()
        } catch { recordFailure(error, sent: sent) }
    }
    func testConnection() async {
        guard !busy, !loading, !mustReload, !dirty, let snapshot else { return }
        guard !snapshot.config.host.isEmpty, !snapshot.config.remoteUser.isEmpty else { error = "Save a destination host and user before testing."; return }
        operation = "Testing…"; error = nil; clearTest()
        defer { operation = nil }
        do {
            guard try await matches(snapshot.config) else { return }
            try Task.checkCancellation()
            let result = try await client.test()
            guard !Task.isCancelled else { return }
            testedConfiguration = snapshot.config; testReceipt = result
        } catch { if !Task.isCancelled { self.error = "Connection test was not confirmed. \(error.localizedDescription)" } }
    }
    // Complete configuration writes need a fresh comparison so observed edits are not overwritten.
    private func matches(_ expected: ArchivePushConfiguration) async throws -> Bool {
        let current = try await client.settings()
        guard current.config == expected else {
            mustReload = true; error = "Archive settings changed on the Pod. Reload and review them before continuing."
            return false
        }
        return true
    }
    private func readBack() async throws {
        try Task.checkCancellation()
        let value = try await client.settings()
        try Task.checkCancellation()
        snapshot = value; draft = .init(value.config); mustReload = false
    }
    private func recordFailure(_ failure: Error, sent: Bool) {
        mustReload = sent
        if receipt != nil { error = "The change was acknowledged, but settings could not be refreshed. Reload before continuing. \(failure.localizedDescription)" }
        else if sent { error = "The change was not confirmed. Reload before retrying. \(failure.localizedDescription)" }
        else { error = "No change was sent. \(failure.localizedDescription)" }
    }
    private func clearTest() { testReceipt = nil; testedConfiguration = nil }
}
