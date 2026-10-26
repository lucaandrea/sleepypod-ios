import Foundation
import Observation

@MainActor @Observable final class HomeRoomWorkspace {
    struct Save: Equatable { let workspaceID: UUID; let base: HomeRoomVersion; let config: HomeRoomConfiguration }
    private let identity = UUID()
    let isSyntheticExample: Bool
    let client: any HomeRoomServing
    private let now: () -> Date
    private(set) var status: HomeRoomStatus?
    private(set) var receivedAt: Date?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var reading = false
    private(set) var saving = false
    private(set) var pending: Save?
    private(set) var base: HomeRoomVersion?
    var draft = HomeRoomConfiguration.empty
    var isActive = false
    private(set) var publisher: HomeRoomPublishers?
    private(set) var publisherError: String?
    private(set) var loadingPublisher = false
    private(set) var history: [HomeRoomHistoryItem] = []
    private(set) var historyLoaded = false
    private(set) var nextHistory: Int64?
    private(set) var historyError: String?
    private(set) var loadingHistory = false
    var hasDraft: Bool { base.map { draft != $0.config } ?? false }
    var conflict: Bool { base != nil && receivedAt != nil && status?.revision != base?.revision }
    var validationError: String? {
        do { _ = try draft.validated(); return nil } catch { return error.localizedDescription }
    }
    var canSave: Bool { base != nil && !saving && !reading && pending == nil && !conflict && validationError == nil && freshServerTime(at: now()) != nil }
    init(client: any HomeRoomServing, syntheticExample: Bool = false, now: @escaping () -> Date = Date.init) { self.client = client; self.isSyntheticExample = syntheticExample; self.now = now }
    func freshServerTime(at date: Date) -> Double? {
        guard isActive, error == nil, let status, let receivedAt else { return nil }
        let elapsed = date.timeIntervalSince(receivedAt)
        guard (0..<15).contains(elapsed) else { return nil }; return Double(status.generatedAt) + elapsed * 1000
    }
    func value(_ observation: HomeRoomObservation, at date: Date) -> Double? {
        guard let status, status.config.enabled, status.connected, observation.status == .fresh,
              let time = freshServerTime(at: date), let expiry = observation.expiresAt, time < Double(expiry),
              status.observations.contains(where: { $0 == observation }) else { return nil }
        return observation.value
    }
    /// Preserve an edited draft when another client changes the saved mapping.
    func refresh() async {
        guard !reading, !saving else { return }
        reading = true; defer { reading = false }
        do {
            let fresh = try await client.status(); try fresh.validate(); try Task.checkCancellation()
            if publisher?.revision != fresh.revision { publisher = nil }
            status = fresh; receivedAt = now(); error = nil
            if let pending {
                self.pending = nil
                if fresh.revision > pending.base.revision && fresh.config == pending.config {
                    base = fresh.version; draft = fresh.config
                    notice = "The saved mapping matches your request. Replace previous publishers with this revision."
                } else if fresh.revision != pending.base.revision {
                    notice = "The saved mapping changed. Your draft is preserved; review it before reloading."
                } else {
                    notice = "The save was not observed. Your draft is preserved. Review the current mapping before saving again."
                }
            } else if base == nil || (!hasDraft && base?.revision != fresh.revision) {
                base = fresh.version; draft = fresh.config
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; receivedAt = nil; publisher = nil } }
    }
    func reloadDraft() {
        guard !saving, pending == nil, let status, freshServerTime(at: now()) != nil else { return }
        base = status.version; draft = status.config; notice = "Loaded the saved mapping."
    }
    func reviewedSave() throws -> Save {
        guard canSave, let base else { throw HomeRoomStatus.issue("Refresh and review the saved configuration before saving.") }
        return .init(workspaceID: identity, base: base, config: try draft.validated())
    }
    /// CAS prevents overwriting another revision. A missing reply leads only to a read, never an automatic retry.
    func save(_ reviewed: Save) async {
        guard canSave, let current = try? reviewedSave(), current == reviewed else { return }
        saving = true; pending = reviewed; notice = nil; publisher = nil; publisherError = nil
        defer { saving = false }
        do {
            let result = try await client.configure(reviewed.config, expectedRevision: reviewed.base.revision)
            guard result.revision == reviewed.base.revision + 1, try result.config.validated() == reviewed.config else {
                throw HomeRoomStatus.issue("The save response did not match the reviewed mapping.")
            }
            base = result; draft = result.config; pending = nil; receivedAt = nil
            notice = "Mapping saved. Generate and replace its Home Assistant publishers, then wait for new measurements."
        } catch {
            receivedAt = nil
            notice = "Save outcome is unconfirmed. Refresh will read the stored revision before another save. \(error.localizedDescription)"
        }
    }
    func canUsePublisher(at date: Date) -> Bool {
        guard let status, let publisher else { return false }
        return publisher.revision == status.revision && status.connected && freshServerTime(at: date) != nil
    }
    func loadPublishers() async {
        guard !loadingPublisher, !saving, pending == nil, let status, status.connected,
              !status.config.mappings.isEmpty, freshServerTime(at: now()) != nil else { return }
        loadingPublisher = true; publisherError = nil; publisher = nil
        defer { loadingPublisher = false }
        do {
            let value = try await client.publishers(); try Task.checkCancellation()
            guard self.status?.revision == status.revision, value.revision == status.revision,
                  value.automations.count == status.config.mappings.count,
                  value.automations.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 * 1024 }),
                  freshServerTime(at: now()) != nil else { throw HomeRoomStatus.issue("The publisher no longer matches the current mapping. Refresh and generate again.") }
            publisher = value
        } catch { if !Task.isCancelled { publisherError = error.localizedDescription } }
    }
    func loadHistory(older: Bool = false) async {
        guard !loadingHistory, !older || nextHistory != nil else { return }
        let cursor = older ? nextHistory : nil
        loadingHistory = true; historyError = nil; defer { loadingHistory = false }
        do {
            let page = try await client.history(before: cursor); try page.validate(before: cursor); try Task.checkCancellation()
            var merged = Dictionary(uniqueKeysWithValues: (older ? history : []).map { ($0.id, $0) })
            for item in page.items { merged[item.id] = item }
            history = Array(merged.values.sorted { $0.id > $1.id }.prefix(25_000)); nextHistory = page.nextBeforeId; historyLoaded = true
        } catch { if !Task.isCancelled { historyError = error.localizedDescription } }
    }
    func historyJSON() throws -> String {
        struct Export: Encodable { let scope: String; let items: [HomeRoomHistoryItem] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(Export(scope: "Only the history pages loaded in this view; historical values are not live readings.", items: history)), as: UTF8.self)
    }
}

@MainActor @Observable final class HomeRoomSession {
    private var scope: String?
    private(set) var workspace: HomeRoomWorkspace?
    private(set) var setupError: String?
    func configure(scope: String, client: (any HomeRoomServing)?, syntheticExample: Bool = false) {
        guard self.scope != scope else { return }
        self.scope = scope; workspace?.isActive = false; workspace = nil; setupError = nil
        if let client { workspace = .init(client: client, syntheticExample: syntheticExample) }
        else { setupError = "Connect to a Sleepypod Core controller to configure room sensors." }
    }
    func configure(scope: String) {
        guard self.scope != scope else { return }
        if APIBackend.current.isDemo {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "uiRoomFixture"), let client = try? HomeRoomDemoFixtureClient() {
                configure(scope: scope, client: client, syntheticExample: true); return
            }
            #endif
            configure(scope: scope, client: DemoHomeRoomClient()); return
        }
        guard APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() else { configure(scope: scope, client: nil); return }
        configure(scope: scope, client: CoreHomeRoomClient(transport: transport))
    }
}
