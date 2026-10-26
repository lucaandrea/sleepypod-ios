import Foundation
import Observation

@MainActor @Observable
final class AutomationWorkspace {
    private(set) var rules: [AutomationRule] = []
    private(set) var globalEnabled: Bool?
    private(set) var diagnostics: AutomationDiagnostics?
    private(set) var timelineActivity: AutomationActivity?
    var timelineError: String?
    private(set) var summaries: [AutomationReplaySummary] = []
    var summariesError: String?
    private(set) var tonight: AutomationTonight?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var ready = false
    private(set) var requiresReload = false
    private(set) var recoveredCreation: AutomationRule?
    var error: String?
    var diagnosticsError: String?
    var tonightError: String?
    var notice: String?
    let client: any AutomationClient
    private var revision = 0
    private let owner = OwnerConnection.revision
    private var pendingCreation: (definition: AutomationDefinition, existingIDs: Set<Int>)?
    var canCreate: Bool { ready && pendingCreation == nil }
    init(client: any AutomationClient) { self.client = client }
    func invalidate() { if saving { requiresReload = true }; revision += 1; loading = false; saving = false; ready = false }
    private func current(_ requested: Int) -> Bool { revision == requested && owner == OwnerConnection.revision && !Task.isCancelled }
    func load(userInitiated: Bool = true) async {
        guard !saving, owner == OwnerConnection.revision, userInitiated || !requiresReload else { return }
        revision += 1; let requested = revision
        loading = true; error = nil
        defer { if revision == requested { loading = false } }
        do {
            async let listed = client.rules()
            async let enabled = client.globalEnabled()
            let result = try await (listed, enabled)
            guard current(requested) else { return }
            rules = result.0; globalEnabled = result.1; ready = true; requiresReload = false
            reconcileCreation()
        } catch { guard current(requested) else { return }; self.error = APIError.message(for: error); ready = false }
    }
    /// A lost create response cannot be replayed: first identify a unique new rule with the exact submitted definition.
    private func reconcileCreation() {
        guard let pendingCreation else { return }
        let matches = rules.filter { !pendingCreation.existingIDs.contains($0.id) && $0.definition == pendingCreation.definition }
        if matches.count == 1 {
            recoveredCreation = matches[0]; self.pendingCreation = nil
            notice = "A matching saved automation was found. Review it before making further changes."
        } else {
            error = "The save result is still uncertain. Your draft is kept. Review the current automations before creating another; this draft will not be sent again automatically."
        }
    }
    func loadDiagnostics() async {
        let requested = revision
        do {
            let result = try await client.diagnostics()
            guard current(requested), !saving else { return }
            diagnostics = result; diagnosticsError = nil
        } catch { guard current(requested) else { return }; diagnostics = nil; diagnosticsError = APIError.message(for: error) }
    }
    func loadTonight() async {
        let requested = revision
        do {
            let result = try await client.tonight()
            guard current(requested), !saving else { return }
            tonight = result; tonightError = nil
        } catch { guard current(requested) else { return }; tonight = nil; tonightError = APIError.message(for: error) }
    }
    func loadTimelineActivity(timeZone: String) async {
        let requested = revision
        do {
            let result = try await client.activity(nightStarts: AutomationActivity.nightStarts(count: 2, timeZone: TimeZone(identifier: timeZone) ?? .current))
            guard current(requested) else { return }
            timelineActivity = result; timelineError = nil
        } catch { guard current(requested) else { return }; timelineActivity = nil; timelineError = APIError.message(for: error) }
    }
    func loadSummaries() async {
        let requested = revision
        do {
            let result = try await client.summaries()
            guard current(requested), !saving else { return }
            summaries = result; summariesError = nil
        } catch { guard current(requested) else { return }; summaries = []; summariesError = APIError.message(for: error) }
    }
    private func replace(_ rule: AutomationRule) {
        rules.removeAll { $0.id == rule.id }; rules.append(rule)
        rules.sort { $0.definition.priority != $1.definition.priority ? $0.definition.priority > $1.definition.priority : $0.id < $1.id }
        diagnostics = nil; summaries.removeAll { $0.id == rule.id }
    }
    // Core has no conditional-write token. Check the original again without flattening the user's draft.
    private func checkOriginal(_ original: AutomationRule, requested: Int) async throws {
        let latest = try await client.rules().first { $0.id == original.id }
        guard current(requested) else { throw CancellationError() }
        guard latest == original else { throw APIError.serverError(message: "This automation changed on another device. Your draft is kept; reload the current rule before saving.") }
    }
    private func mutationFailed(_ failure: Error, requested: Int, sent: Bool) {
        guard current(requested) else { return }
        error = APIError.message(for: failure)
        if sent {
            requiresReload = true; ready = false
            error = "The controller did not confirm the change. Reload its current state before trying again. " + (error ?? "")
        }
    }
    func save(_ definition: AutomationDefinition, original: AutomationRule?) async -> Bool {
        guard !saving, !loading, ready, !Task.isCancelled, owner == OwnerConnection.revision, original != nil || canCreate else { return false }
        if let validation = definition.validation { error = validation; return false }
        revision += 1; let requested = revision
        saving = true; error = nil; notice = nil
        var sent = false
        defer { if revision == requested { saving = false } }
        do {
            let saved: AutomationRule
            if let original {
                try await checkOriginal(original, requested: requested)
                sent = true; saved = try await client.update(id: original.id, definition: definition)
            } else {
                pendingCreation = (definition, Set(rules.map(\.id)))
                recoveredCreation = nil; sent = true
                saved = try await client.create(definition)
            }
            guard current(requested) else { return false }
            if original == nil { pendingCreation = nil }; replace(saved); notice = "Automation saved."; return true
        } catch { mutationFailed(error, requested: requested, sent: sent); return false }
    }
    func setMode(_ mode: AutomationMode, for original: AutomationRule) async {
        guard !saving, !loading, ready, !Task.isCancelled, owner == OwnerConnection.revision else { return }
        revision += 1; let requested = revision
        saving = true; error = nil; notice = nil; var sent = false
        defer { if revision == requested { saving = false } }
        do {
            try await checkOriginal(original, requested: requested)
            sent = true; let saved = try await client.mode(id: original.id, mode: mode)
            guard current(requested) else { return }; replace(saved)
        } catch { mutationFailed(error, requested: requested, sent: sent) }
    }
    func setGlobal(_ enabled: Bool) async {
        guard !saving, !loading, ready, !Task.isCancelled, owner == OwnerConnection.revision else { return }
        revision += 1; let requested = revision; saving = true; error = nil
        defer { if revision == requested { saving = false } }
        do {
            let result = try await client.setGlobalEnabled(enabled)
            guard current(requested) else { return }; globalEnabled = result; diagnostics = nil
        } catch { mutationFailed(error, requested: requested, sent: true) }
    }
    func delete(_ original: AutomationRule) async -> Bool {
        guard !saving, !loading, ready, !Task.isCancelled, owner == OwnerConnection.revision else { return false }
        revision += 1; let requested = revision; saving = true; error = nil; var sent = false
        defer { if revision == requested { saving = false } }
        do {
            try await checkOriginal(original, requested: requested)
            sent = true; try await client.delete(id: original.id)
            guard current(requested) else { return false }
            rules.removeAll { $0.id == original.id }; diagnostics = nil; notice = "Automation deleted."; return true
        } catch { mutationFailed(error, requested: requested, sent: sent); return false }
    }
}

@MainActor @Observable
final class AutomationBacktestWorkspace {
    var side: Side
    var night: Int?
    private(set) var nights: [AutomationNight] = []
    private(set) var result: AutomationBacktest?
    private(set) var loading = false
    private(set) var running = false
    var error: String?
    private let client: any AutomationClient
    private var revision = 0
    private var replayed: AutomationDefinition?
    private var replayedSide: Side?
    private var replayedNight: Int?
    init(side: Side, client: any AutomationClient) { self.side = side; self.client = client }
    func isCurrent(_ definition: AutomationDefinition) -> Bool { replayed == definition && replayedSide == side && replayedNight == night }
    func load() async {
        revision += 1; let requested = revision; let selected = side
        loading = true; running = false; result = nil; error = nil
        do {
            let values = try await client.nights(side: selected)
            guard revision == requested, side == selected, !Task.isCancelled else { return }
            nights = values; night = values.first?.id
        } catch { guard revision == requested else { return }; nights = []; night = nil; self.error = error.localizedDescription }
        if revision == requested { loading = false }
    }
    func run(_ definition: AutomationDefinition) async {
        guard !loading, !running, definition.validation == nil else { return }
        revision += 1; let requested = revision; let selected = side; let selectedNight = night
        running = true; error = nil
        defer { if revision == requested { running = false } }
        do {
            let response = try await client.backtest(definition, side: selected, night: selectedNight)
            guard revision == requested, side == selected, night == selectedNight, !Task.isCancelled else { return }
            result = response; replayed = definition; replayedSide = selected; replayedNight = selectedNight
        } catch { guard revision == requested else { return }; self.error = error.localizedDescription; result = nil }
        if revision == requested { running = false }
    }
}
