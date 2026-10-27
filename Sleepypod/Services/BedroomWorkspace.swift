import Foundation
import Observation

@MainActor @Observable final class BedroomWorkspace {
    let client: any BedroomServing
    private let now: () -> Date
    private(set) var status: BedroomStatus?
    private(set) var receivedAt: Date?
    private(set) var error: String?
    private(set) var reading = false
    private(set) var saving = false
    private(set) var pending: BedroomVersion?
    private(set) var notice: String?
    var isActive = false
    init(client: any BedroomServing, now: @escaping () -> Date = Date.init) { self.client = client; self.now = now }

    /// Advance the controller's clock using local elapsed time, not the phone's clock offset.
    func serverTime(at date: Date) -> Double? {
        guard isActive, error == nil, let status, let receivedAt else { return nil }
        let elapsed = date.timeIntervalSince(receivedAt)
        guard (0..<15).contains(elapsed) else { return nil }
        return Double(status.generatedAt) + elapsed * 1000
    }
    func value(_ item: BedroomObservation, at date: Date) -> Double? {
        guard let status, status.config.enabled, item.source.enabled, status.observations.contains(item),
              item.status == .fresh, let expires = item.expiresAt, let time = serverTime(at: date), time < Double(expires) else { return nil }
        return item.value
    }
    func aggregate(_ metric: BedroomMetric, at date: Date) -> Double? {
        guard let status, status.config.enabled, let aggregate = status.aggregates.first(where: { $0.metric == metric }),
              aggregate.status == "ready", let expires = aggregate.expiresAt, let time = serverTime(at: date), time < Double(expires) else { return nil }
        return aggregate.value
    }
    func guidance(at date: Date) -> BedroomGuidance? {
        guard let status, status.config.enabled, status.guidance.state == "ready", let expiry = status.guidance.expiresAt,
              let time = serverTime(at: date), time < Double(expiry) else { return nil }
        return status.guidance
    }
    func refresh() async {
        guard !reading, !saving else { return }
        reading = true
        defer { reading = false }
        do {
            let result = try await client.status()
            try result.validate()
            try Task.checkCancellation()
            status = result; receivedAt = now(); error = nil
            if let pending {
                notice = result.revision > pending.revision && result.config == pending.config
                    ? "Your device selection is saved. Publishers need the new revision."
                    : "The save was not confirmed. Review the current device selection before saving again."
                self.pending = nil
            }
        } catch {
            receivedAt = nil
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
    /// A missing reply is reconciled by reading; never retry a configuration write automatically.
    func save(_ config: BedroomConfiguration, original: BedroomVersion) async -> Bool {
        guard !saving, !reading, pending == nil, status?.version == original, serverTime(at: now()) != nil else { return false }
        do { try config.validate() } catch { self.error = error.localizedDescription; return false }
        saving = true; pending = .init(revision: original.revision, config: config); notice = nil
        defer { saving = false }
        do {
            let result = try await client.configure(config, expectedRevision: original.revision)
            guard result.revision == original.revision + 1, result.config == config else { throw BedroomStatus.issue }
            pending = nil; receivedAt = nil
            notice = "Device selection saved. Publishers need the new revision before fresh readings can arrive."
            return true
        } catch {
            receivedAt = nil
            notice = "Save outcome is unconfirmed. Refresh to check the saved selection."
            return false
        }
    }
}

@MainActor @Observable final class BedroomSession {
    private var scope: String?
    private(set) var workspace: BedroomWorkspace?
    private(set) var isSyntheticExample = false
    func configure(scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope; workspace?.isActive = false; workspace = nil; isSyntheticExample = false
        #if DEBUG
        if APIBackend.current.isDemo, UserDefaults.standard.bool(forKey: "uiBedroomFixture"), let client = try? BedroomDemoFixtureClient() {
            workspace = .init(client: client); isSyntheticExample = true; return
        }
        #endif
        if APIBackend.current.isDemo { workspace = .init(client: DemoBedroomClient()) }
        else if APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() {
            workspace = .init(client: CoreBedroomClient(transport: transport))
        }
    }
}
