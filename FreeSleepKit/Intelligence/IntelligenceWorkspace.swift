import Foundation
import HealthKit
import Observation

@MainActor @Observable
final class IntelligenceWorkspace {
    static let shared = IntelligenceWorkspace()
    var provider: IntelligenceProvider { didSet { if provider != oldValue { modelID = modelIDs[provider.rawValue] ?? provider.models[0]; catalog = []; message = nil; persistPreferences() } } }
    var modelID: String { didSet { modelIDs[provider.rawValue] = modelID; persistPreferences() } }
    var localAddress: String { didSet { defaults.set(localAddress, forKey: "intelligence.localAddress") } }
    var selectedSource: String { didSet { defaults.set(selectedSource, forKey: "intelligence.source") } }
    var refreshHistory: Bool { didSet { defaults.set(refreshHistory, forKey: "intelligence.refresh") } }
    var monthlyLimit: Int { didSet { defaults.set(max(0, min(1000, monthlyLimit)), forKey: "intelligence.limit") } }
    var question = "What has changed in my sleep, and which one small routine experiment should I try next?"
    private(set) var archive = PersonalIntelligenceArchive()
    private(set) var catalog: [String] = []
    private(set) var message: String?
    private(set) var busy = false
    private(set) var keySaved = false
    private(set) var attempts = 0
    private let defaults: UserDefaults
    private let store: PersonalIntelligenceStore
    private var modelIDs: [String: String]
    private var operation: Task<Void, Never>?
    private var lastRefreshAttempt = Date.distantPast
    private var restored = false

    init(defaults: UserDefaults = .standard, store: PersonalIntelligenceStore = .init()) {
        self.defaults = defaults; self.store = store
        let selected = IntelligenceProvider(rawValue: defaults.string(forKey: "intelligence.provider") ?? "") ?? .apple
        provider = selected
        let savedModels = defaults.dictionary(forKey: "intelligence.models") as? [String: String] ?? [:]
        modelIDs = savedModels
        modelID = savedModels[selected.rawValue] ?? selected.models[0]
        localAddress = defaults.string(forKey: "intelligence.localAddress") ?? ""
        selectedSource = defaults.string(forKey: "intelligence.source") ?? ""
        refreshHistory = defaults.object(forKey: "intelligence.refresh") as? Bool ?? true
        monthlyLimit = defaults.object(forKey: "intelligence.limit") as? Int ?? 100
        updateAttempts()
    }
    var source: HealthHistory.Source? { archive.history.sources.first { $0.id == selectedSource } ?? archive.history.sources.first }
    var facts: [SleepFact] {
        HealthHistoryAnalyzer.facts(source: source, now: .now, timeZone: TimeZone(identifier: archive.history.timeZone) ?? .current)
    }
    var choices: [String] { Array(Set(provider.models + catalog + (modelID.isEmpty ? [] : [modelID]))).sorted() }
    var reportInProgress: Bool { operation != nil }
    var ready: Bool { provider == .apple ? AppleIntelligenceClient.available : provider == .ollama ? !localAddress.isEmpty : keySaved }
    func restore() {
        if !restored {
            do {
                archive = try store.read(); restored = true
                if !archive.history.sources.contains(where: { $0.id == selectedSource }) { selectedSource = archive.history.sources.first?.id ?? "" }
            }
            catch { message = "Saved Health history is unavailable while this device is locked, or the archive could not be read." }
        }
        checkKey(); updateAttempts()
    }
    func checkKey() { keySaved = !((try? ProviderKeyStore.read(provider)) ?? "").isEmpty }
    func saveKey(_ value: String) {
        do { try ProviderKeyStore.save(value, for: provider); checkKey(); message = "Key saved on this device. Run the connection test to verify model access." }
        catch { message = error.localizedDescription }
    }
    func removeKey() {
        do { try ProviderKeyStore.remove(provider); checkKey(); message = "Key removed from this device." }
        catch { message = error.localizedDescription }
    }
    func refreshModels() async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do {
            catalog = try await ProviderCatalog().models(provider: provider, key: ProviderKeyStore.read(provider), localAddress: localAddress)
            message = "Loaded \(catalog.count) model IDs. Availability in the list does not guarantee this report format is supported."
        } catch { message = "Could not load models. \(error.localizedDescription)" }
    }
    func testModel() async {
        guard !busy, !AppMode.isDemo else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            let input = try request(prompt: "Reply with one short sentence confirming you can generate text. No personal data is included.", diagnostic: true)
            try reserve(provider: input.provider)
            let reply = try await NativeModelClient().generate(input)
            message = "Connected to \(reply.model). A text response was received. No Health or Pod data was sent."
        } catch { message = error is CancellationError ? "Test cancelled." : error.localizedDescription }
    }
    func importHistory(authorize: Bool = true) async {
        guard !busy, !AppMode.isDemo else { return }
        busy = true; message = "Reading accessible Health history…"; lastRefreshAttempt = .now
        defer { busy = false }
        do {
            let reader = HealthHistoryReader(store: HKHealthStore())
            if authorize { try await reader.authorize(); defaults.set(true, forKey: "intelligence.healthRequested") }
            let history = try await reader.read()
            try Task.checkCancellation()
            var updated = archive; updated.history = history
            try store.write(updated); archive = updated
            if !history.sources.contains(where: { $0.id == selectedSource }) { selectedSource = history.sources.first?.id ?? "" }
            message = history.sources.isEmpty ? "No readable sleep records were returned. Health does not reveal whether access was denied; review permissions or try again after data syncs."
                : "History refreshed. Choose one sleep source below. No Health data has been sent to a model."
        } catch { message = error is CancellationError ? "History refresh cancelled. The previous import is unchanged." : error.localizedDescription }
    }
    func refreshOnActivation() async {
        restore()
        guard refreshHistory, defaults.bool(forKey: "intelligence.healthRequested"), !busy,
              Date.now.timeIntervalSince(archive.history.importedAt) >= 6 * 3600,
              Date.now.timeIntervalSince(lastRefreshAttempt) >= 15 * 60 else { return }
        await importHistory(authorize: false)
    }
    func generate(facts: [SleepFact], consent: Bool) {
        guard !busy, !facts.isEmpty, !AppMode.isDemo, !provider.leavesDevice || consent else { return }
        busy = true; message = nil
        let sourceName = source?.name ?? "Pod"
        do {
            let input = try request(prompt: PersonalReportPrompt.make(facts: facts, question: question))
            try reserve(provider: input.provider)
            operation = Task {
                defer { busy = false; operation = nil }
                do {
                    let reply = try await NativeModelClient().generate(input)
                    try Task.checkCancellation()
                    let report = PersonalSleepReport(id: UUID(), createdAt: .now, provider: input.provider, model: reply.model,
                        source: sourceName, facts: facts, text: reply.text, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens)
                    var updated = archive; updated.reports = Array(([report] + updated.reports).prefix(30))
                    try store.write(updated); archive = updated
                    message = "Report saved privately on this device. Suggested changes are yours to review."
                } catch { message = error is CancellationError ? "Report cancelled." : error.localizedDescription }
            }
        } catch { busy = false; message = error.localizedDescription }
    }
    func cancel() { operation?.cancel() }
    func forgetHistory() {
        guard !busy else { return }
        do {
            let empty = PersonalIntelligenceArchive(); try store.write(empty); archive = empty
            defaults.set(false, forKey: "intelligence.healthRequested"); refreshHistory = false
            message = "Local history and reports removed. Apple Health records and API keys are unchanged."
        } catch { message = "The local archive could not be cleared." }
    }
    private func request(prompt: String, diagnostic: Bool = false) throws -> ModelRequest {
        ModelRequest(provider: provider, model: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            key: try ProviderKeyStore.read(provider), localAddress: localAddress,
            instructions: diagnostic ? "Follow the brief test request." : PersonalReportPrompt.instructions, prompt: prompt, diagnostic: diagnostic)
    }
    private func persistPreferences() {
        defaults.set(provider.rawValue, forKey: "intelligence.provider"); defaults.set(modelIDs, forKey: "intelligence.models")
    }
    private func updateAttempts() {
        let month = String(Date.now.ISO8601Format().prefix(7))
        if defaults.string(forKey: "intelligence.month") != month {
            defaults.set(month, forKey: "intelligence.month"); defaults.set(0, forKey: "intelligence.attempts")
        }
        attempts = defaults.integer(forKey: "intelligence.attempts")
    }
    private func reserve(provider: IntelligenceProvider) throws {
        guard provider.needsKey else { return }
        updateAttempts()
        guard attempts < max(0, min(1000, monthlyLimit)) else { throw PodError.message("This device’s monthly model request limit has been reached. Adjust the limit in AI settings.") }
        attempts += 1; defaults.set(attempts, forKey: "intelligence.attempts")
    }
}
