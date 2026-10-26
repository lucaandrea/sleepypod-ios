import Foundation
import Observation

@MainActor @Observable final class MQTTSettingsWorkspace {
    private let client: any MQTTSettingsClient
    private var revision = 0
    private var testRevision = UUID()
    var draft: MQTTSettingsDraft?
    private(set) var settings: MQTTSettings?
    private(set) var status: MQTTBridgeStatus?
    private(set) var statusAt: Date?
    private(set) var settingsError: String?
    private(set) var statusError: String?
    private(set) var actionError: String?
    private(set) var saveReceipt: String?
    private(set) var testResult: MQTTTestResult?
    private(set) var testedInput: MQTTConnectionTest?
    private(set) var loading = false
    private(set) var loadingStatus = false
    private(set) var saving = false
    private(set) var testing = false
    private(set) var mustRefresh = false
    init(client: any MQTTSettingsClient) { self.client = client }
    var busy: Bool { saving || testing }
    var dirty: Bool { guard let draft, let settings else { return false }; return !draft.patch(comparedTo: settings).isEmpty }
    var currentTestResult: MQTTTestResult? { draft?.testRequest == testedInput ? testResult : nil }
    func statusFresh(now: Date = .now) -> Bool { statusError == nil && SensorObservation.fresh(statusAt, age: 15, now: now) }
    func loadSettings(discardDraft: Bool = false) async {
        guard !loading, !busy else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await client.settings()
            guard !Task.isCancelled else { return }
            if draft == nil || discardDraft || !dirty { draft = .init(value) }
            settings = value; settingsError = nil; mustRefresh = false
            if discardDraft { saveReceipt = nil; actionError = nil; clearTest() }
        } catch {
            guard !Task.isCancelled else { return }
            settingsError = safe(error.localizedDescription)
        }
    }
    func refreshStatus() async {
        guard !loadingStatus, !saving else { return }
        loadingStatus = true
        let request = revision
        defer { if revision == request { loadingStatus = false } }
        do {
            let value = try await client.status()
            guard !Task.isCancelled, revision == request else { return }
            status = value; statusAt = .now; statusError = nil
        } catch {
            guard !Task.isCancelled, revision == request else { return }
            statusError = safe(error.localizedDescription)
        }
    }
    func save() async {
        guard !busy, !loading, !mustRefresh, let draft, let baseline = settings else { return }
        let patch = draft.patch(comparedTo: baseline)
        guard !patch.isEmpty else { return }
        if let issue = draft.topicIssue ?? (draft.enabled ? draft.brokerIssue : nil) { actionError = issue; return }
        saving = true; actionError = nil; saveReceipt = nil; revision += 1; loadingStatus = false
        var sent = false
        defer { saving = false }
        do {
            let current = try await client.settings()
            guard !Task.isCancelled else { return }
            if conflicts(patch, baseline: baseline, current: current) {
                settings = current; mustRefresh = true
                actionError = "The Pod’s settings changed while you were editing. Reload and review them before saving."
                return
            }
            sent = true
            try await client.save(patch)
            // A save receipt confirms persistence only. Connection state is fetched independently.
            self.draft?.password = ""; clearTest()
            guard !Task.isCancelled else { mustRefresh = true; return }
            saveReceipt = "Configuration saved. The bridge may still be reconnecting."
            let confirmed = try await client.settings()
            guard !Task.isCancelled else { mustRefresh = true; return }
            settings = confirmed; self.draft = .init(confirmed); settingsError = nil; mustRefresh = false
        } catch {
            mustRefresh = sent
            if saveReceipt != nil {
                actionError = "Saved, but refreshed settings are unavailable. Reload before editing further. \(draft.safeMessage(error.localizedDescription))"
            } else {
                actionError = sent ? "Save outcome needs a fresh read before retrying. \(draft.safeMessage(error.localizedDescription))"
                    : "Could not read the current settings; no change was sent. \(draft.safeMessage(error.localizedDescription))"
            }
        }
        saving = false
        await refreshStatus()
    }
    func testConnection() async {
        guard !busy, !loading, let draft else { return }
        guard draft.brokerIssue == nil else { actionError = draft.brokerIssue; return }
        testing = true; actionError = nil; clearTest()
        let request = draft.testRequest, revision = testRevision
        defer { testing = false }
        do {
            let result = try await client.test(request)
            guard !Task.isCancelled, testRevision == revision else { return }
            testedInput = request
            testResult = .init(ok: result.ok, error: result.error.map(draft.safeMessage))
        } catch {
            guard !Task.isCancelled, testRevision == revision else { return }
            testedInput = request; testResult = .init(ok: false, error: draft.safeMessage(error.localizedDescription))
        }
    }
    func clearSecret() { draft?.password = ""; clearTest() }
    private func clearTest() { testRevision = UUID(); testResult = nil; testedInput = nil }
    private func safe(_ message: String) -> String { draft?.safeMessage(message) ?? message }
    private func conflicts(_ patch: MQTTSettingsPatch, baseline: MQTTSettings, current: MQTTSettings) -> Bool {
        (patch.enabled != nil && baseline.enabled != current.enabled)
            || (patch.url != nil && baseline.url != current.url)
            || (patch.username != nil && baseline.username != current.username)
            || (patch.topicPrefix != nil && baseline.topicPrefix != current.topicPrefix)
            || (patch.haDiscovery != nil && baseline.haDiscovery != current.haDiscovery)
            || (patch.tlsEnabled != nil && baseline.tlsEnabled != current.tlsEnabled)
    }
}
