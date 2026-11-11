import Foundation
import HealthKit
import Observation
import UIKit

/// A separately opted-in, encrypted context archive. No controller or provider is reachable here.
@MainActor @Observable
final class DaytimeContextWorkspace {
    static let shared = DaytimeContextWorkspace()
    static let unreadableArchiveMessage = "Saved daytime context could not be read. You can remove its local copy below, then choose Health data again. The existing archive has not been replaced."
    private var saved = DaytimeContextArchive()
    private var loadedScope: String?
    private var restored = false
    private var generation = UUID()
    private var running = false
    private var notice: String?
    private var lastAttempt: Date?
    private let store: DaytimeContextStore
    private let readContext: @MainActor () async throws -> DaytimeContext
    private let authorize: @MainActor () async throws -> Void
    private let protectedDataAvailable: @MainActor () -> Bool
    private let scope: @MainActor () -> String?
    private let now: @MainActor () -> Date

    init(store: DaytimeContextStore = .init(),
         readContext: @escaping @MainActor () async throws -> DaytimeContext = { try await DaytimeContextReader(store: HKHealthStore()).read() },
         authorize: @escaping @MainActor () async throws -> Void = { try await DaytimeContextReader(store: HKHealthStore()).authorize() },
         protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
         scope: @escaping @MainActor () -> String? = DaytimeContextWorkspace.ownerScope,
         now: @escaping @MainActor () -> Date = { .now }) {
        self.store = store; self.readContext = readContext; self.authorize = authorize
        self.protectedDataAvailable = protectedDataAvailable; self.scope = scope; self.now = now
    }

    var archive: DaytimeContextArchive { current ? saved : .init() }
    var busy: Bool { current && running }
    var message: String? { current ? notice : nil }
    var canRemoveLocalCopy: Bool { current && (saved.enabled || !restored) }
    private var current: Bool {
        loadedScope != nil && loadedScope == scope() && !PersonalWorkspaceBoundary.isActive && !AppMode.isDemo && protectedDataAvailable()
    }

    static func ownerScope() -> String? {
        guard !PersonalWorkspaceBoundary.isActive, !AppMode.isDemo else { return nil }
        let values = ["apiBackend", "podURL", "podIPAddress", "ownerConnectionRevision", "household.boundaryRevision"]
            .map { UserDefaults.standard.string(forKey: $0) ?? "" }
        guard let encoded = try? JSONEncoder().encode(values) else { return nil }
        return "device-owner|" + encoded.base64EncodedString()
    }

    func restore() {
        guard !PersonalWorkspaceBoundary.isActive, !AppMode.isDemo, protectedDataAvailable(), let identity = scope() else {
            suspend(); return
        }
        if loadedScope != identity { suspend(); loadedScope = identity }
        guard !restored else { return }
        do { saved = try store.read(scope: identity); restored = true }
        catch { notice = Self.unreadableArchiveMessage }
    }

    /// Withdraw memory immediately on lock, backgrounding or identity changes; late reads cannot write.
    func suspend() {
        generation = UUID(); running = false; restored = false; loadedScope = nil
        saved = .init(); notice = nil; lastAttempt = nil
    }

    func importContext(requestPermission: Bool) async {
        restore()
        guard current, restored, !running, requestPermission || saved.enabled, let identity = loadedScope else { return }
        let token = generation
        running = true; notice = nil; lastAttempt = now()
        defer { if generation == token { running = false } }
        do {
            if requestPermission { try await authorize() }
            guard valid(token, identity) else { return }
            try Task.checkCancellation()
            let snapshot = try await readContext()
            try snapshot.validate()
            guard valid(token, identity), snapshot.importedAt <= now() else { throw DaytimeContextError.changedIdentity }
            try Task.checkCancellation()
            let updated = DaytimeContextArchive(enabled: true, snapshot: snapshot)
            try store.write(updated, scope: identity); saved = updated
            notice = snapshot.observations.isEmpty
                ? "No readable context records were returned. Health does not reveal whether access was denied."
                : "Context refreshed privately on this device. Sources remain separate."
        } catch {
            guard valid(token, identity) else { return }
            notice = error is CancellationError ? "Refresh cancelled. The previous import is unchanged."
                : "Context could not be refreshed. The previous import is unchanged; unlock the device and check Health access before trying again."
        }
    }

    func refreshOnActivation() async {
        restore()
        guard current, restored, saved.enabled, !running,
              HealthHistoryRefreshPolicy.shouldRefresh(now: now(), importedAt: saved.snapshot?.importedAt ?? .distantPast,
                  lastAttempt: lastAttempt, enabled: true, requested: true) else { return }
        await importContext(requestPermission: false)
    }

    func forget() {
        restore()
        guard current, let identity = loadedScope else { return }
        do {
            try store.remove(scope: identity)
            suspend(); loadedScope = identity; restored = true
            notice = "Daytime context turned off and its local copy removed. Your Apple Health records are unchanged."
        } catch { notice = "The local copy could not be removed. Try again after unlocking the device." }
    }

    private func valid(_ token: UUID, _ identity: String) -> Bool { generation == token && current && loadedScope == identity }
}
