import Foundation
import Observation

@MainActor @Observable
final class AutomationWorkspace {
    private(set) var rules: [AutomationRule] = []
    private(set) var globalEnabled: Bool?
    private(set) var diagnostics: AutomationDiagnostics?
    private(set) var tonight: AutomationTonight?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var ready = false
    var error: String?
    var diagnosticsError: String?
    var tonightError: String?
    var notice: String?
    let client: any AutomationClient
    private var revision = 0
    init(client: any AutomationClient) { self.client = client }
    func load() async {
        guard !saving else { return }
        revision += 1; let requested = revision
        loading = true; error = nil
        do {
            async let listed = client.rules()
            async let enabled = client.globalEnabled()
            let result = try await (listed, enabled)
            guard revision == requested, !Task.isCancelled else { return }
            rules = result.0; globalEnabled = result.1; ready = true
        } catch { guard revision == requested, !Task.isCancelled else { return }; self.error = error.localizedDescription; ready = false }
        if revision == requested { loading = false }
    }
    func loadDiagnostics() async {
        let requested = revision
        do {
            let result = try await client.diagnostics()
            guard revision == requested, !saving, !Task.isCancelled else { return }
            diagnostics = result; diagnosticsError = nil
        } catch { guard revision == requested, !Task.isCancelled else { return }; diagnostics = nil; diagnosticsError = error.localizedDescription }
    }
    func loadTonight() async {
        let requested = revision
        do {
            let result = try await client.tonight()
            guard revision == requested, !saving, !Task.isCancelled else { return }
            tonight = result; tonightError = nil
        } catch { guard revision == requested, !Task.isCancelled else { return }; tonight = nil; tonightError = error.localizedDescription }
    }
    private func replace(_ rule: AutomationRule) {
        rules.removeAll { $0.id == rule.id }; rules.append(rule)
        rules.sort { $0.definition.priority != $1.definition.priority ? $0.definition.priority > $1.definition.priority : $0.id < $1.id }
        diagnostics = nil
    }
    // Core has no conditional-write token. A fresh read catches observed edits without flattening the user's draft.
    private func checkOriginal(_ original: AutomationRule) async throws {
        let current = try await client.rules().first { $0.id == original.id }
        guard current == original else { throw APIError.serverError(message: "This automation changed on another device. Your draft is kept; reload the current rule before saving.") }
    }
    func save(_ definition: AutomationDefinition, original: AutomationRule?) async -> Bool {
        guard !saving, !loading, ready else { return false }
        if let validation = definition.validation { error = validation; return false }
        revision += 1; saving = true; error = nil; notice = nil
        defer { saving = false }
        do {
            if let original {
                try await checkOriginal(original)
                replace(try await client.update(id: original.id, definition: definition))
            } else { replace(try await client.create(definition)) }
            notice = "Automation saved."; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setMode(_ mode: AutomationMode, for original: AutomationRule) async {
        guard !saving, !loading, ready else { return }
        revision += 1; saving = true; error = nil; notice = nil; defer { saving = false }
        do { try await checkOriginal(original); replace(try await client.mode(id: original.id, mode: mode)) }
        catch { self.error = error.localizedDescription }
    }
    func setGlobal(_ enabled: Bool) async {
        guard !saving, !loading, ready else { return }
        revision += 1; saving = true; error = nil; defer { saving = false }
        do { globalEnabled = try await client.setGlobalEnabled(enabled); diagnostics = nil }
        catch { self.error = error.localizedDescription }
    }
    func delete(_ original: AutomationRule) async -> Bool {
        guard !saving, !loading, ready else { return false }
        revision += 1; saving = true; error = nil; defer { saving = false }
        do {
            try await checkOriginal(original); try await client.delete(id: original.id)
            rules.removeAll { $0.id == original.id }; diagnostics = nil; notice = "Automation deleted."; return true
        } catch { self.error = error.localizedDescription; return false }
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
