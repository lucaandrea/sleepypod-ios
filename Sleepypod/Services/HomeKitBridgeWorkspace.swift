import Foundation
import Observation

@MainActor @Observable final class HomeKitBridgeWorkspace {
    private let client: any HomeKitBridgeClient
    private var revision = 0
    private(set) var status: HomeKitBridgeStatus?
    private(set) var receivedAt: Date?
    private(set) var error: String?
    private(set) var actionError: String?
    private(set) var receipt: String?
    private(set) var loading = false
    private(set) var changing = false
    private(set) var mustRefresh = false
    init(client: any HomeKitBridgeClient) { self.client = client }
    func fresh(now: Date = .now) -> Bool { error == nil && SensorObservation.fresh(receivedAt, age: 15, now: now) }
    var canChange: Bool { fresh() && !changing && !mustRefresh && status?.transitioning != true }
    func refresh() async {
        guard !loading, !changing else { return }
        loading = true
        let request = revision
        defer { if revision == request { loading = false } }
        do {
            let value = try await client.status()
            guard !Task.isCancelled, revision == request else { return }
            status = value; receivedAt = .now; error = nil; mustRefresh = false
        } catch {
            guard !Task.isCancelled, revision == request else { return }
            self.error = error.localizedDescription
        }
    }
    func setEnabled(_ enabled: Bool) async { await change(reset: false, enabled: enabled) }
    func resetPairing() async { await change(reset: true, enabled: nil) }
    // Invalidate polls begun before a mutation; only its response or a later read may replace state.
    private func change(reset: Bool, enabled: Bool?) async {
        guard canChange, let previous = status else { return }
        if reset && (!previous.enabled || !previous.running || previous.pairedControllers.isEmpty) { return }
        revision += 1; loading = false; changing = true; actionError = nil; receipt = nil
        defer { changing = false }
        do {
            let value: HomeKitBridgeStatus
            if reset { value = try await client.resetPairing() }
            else { value = try await client.setEnabled(enabled ?? previous.enabled) }
            guard !Task.isCancelled else { mustRefresh = true; receivedAt = nil; return }
            status = value; receivedAt = .now; error = nil; mustRefresh = false
            receipt = reset ? "Pairing reset. Remove the old bridge from Apple Home before pairing again."
                : value.enabled == enabled ? "Bridge setting confirmed by the Pod." : "The Pod returned a different bridge state. Review it before trying again."
        } catch {
            receivedAt = nil; mustRefresh = true
            actionError = "Change not confirmed. Refresh the bridge state before trying again. \(error.localizedDescription)"
        }
    }
}
