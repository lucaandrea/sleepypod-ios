import Foundation
import HealthKit
import Observation
import UIKit

@MainActor @Observable public final class PersonalHealthWorkspace {
    public enum Status: Equatable { case consentRequired, ready, anotherAccount, unavailable, invalidated }
    public struct SourceSummary: Identifiable {
        public let id: String
        public let name: String
        public let recordedDays: Int
    }

    public let access: PersonalHealthAccess
    public let displayName: String
    private var storedStatus = Status.unavailable
    private var storedMessage: String?
    private var storedBusy = false
    private var archive: PersonalHealthArchive?
    private var invalidated = false
    private var operation = UUID()
    private var lastAttempt: Date?
    private var historyTask: Task<HealthHistory, Error>?
    private let store: PersonalHealthStore
    private let currentAccess: @MainActor () -> PersonalHealthAccess?
    private let importPermitted: @MainActor () -> Bool
    private let protectedDataAvailable: @MainActor () -> Bool
    private let authorizeHistory: @MainActor () async throws -> Void
    private let readHistory: @MainActor () async throws -> HealthHistory
    private let now: @MainActor () -> Date
    private let allowedMode: @MainActor () -> Bool

    public convenience init(access: PersonalHealthAccess, displayName: String,
                            currentAccess: @escaping @MainActor () -> PersonalHealthAccess?,
                            importPermitted: @escaping @MainActor () -> Bool, snapshots: PrivateSnapshotStore? = nil) {
        self.init(access: access, displayName: displayName, store: .init(snapshots: snapshots ?? .init(namespace: "personal-health-v1")), currentAccess: currentAccess,
                  importPermitted: importPermitted, protectedDataAvailable: { UIApplication.shared.isProtectedDataAvailable },
                  authorizeHistory: { try await HealthHistoryReader(store: HKHealthStore()).authorize() },
                  readHistory: { try await HealthHistoryReader(store: HKHealthStore()).read() })
    }

    init(access: PersonalHealthAccess, displayName: String, store: PersonalHealthStore,
         currentAccess: @escaping @MainActor () -> PersonalHealthAccess?, importPermitted: @escaping @MainActor () -> Bool,
         protectedDataAvailable: @escaping @MainActor () -> Bool,
         authorizeHistory: @escaping @MainActor () async throws -> Void,
         readHistory: @escaping @MainActor () async throws -> HealthHistory, now: @escaping @MainActor () -> Date = { .now },
         allowedMode: @escaping @MainActor () -> Bool = { !AppMode.isDemo && PersonalWorkspaceBoundary.isActive }) {
        self.access = access; self.displayName = displayName; self.store = store
        self.currentAccess = currentAccess; self.importPermitted = importPermitted
        self.protectedDataAvailable = protectedDataAvailable; self.authorizeHistory = authorizeHistory
        self.readHistory = readHistory; self.now = now
        self.allowedMode = allowedMode
    }

    private var readable: Bool {
        !invalidated && allowedMode() && protectedDataAvailable() && currentAccess() == access
    }
    public var status: Status { readable ? storedStatus : .invalidated }
    public var message: String? { readable ? storedMessage : nil }
    public var busy: Bool { readable && storedBusy }
    public var isInvalidated: Bool { invalidated }
    public var mayEnroll: Bool { readable && importPermitted() && !storedBusy && storedStatus == .consentRequired }
    public var mayImport: Bool { readable && importPermitted() && !storedBusy && storedStatus == .ready }
    public var importedAt: Date? { readable ? archive?.history?.importedAt : nil }
    public var selectedSource: String? { readable ? archive?.selectedSource : nil }
    public var automaticRefresh: Bool { readable && archive?.automaticRefresh == true }
    public var sources: [SourceSummary] {
        guard readable else { return [] }
        return archive?.history?.sources.map { .init(id: $0.id, name: $0.name, recordedDays: $0.nights.count) } ?? []
    }
    var history: HealthHistory? { readable ? archive?.history : nil }

    public func restore() {
        guard readable, !storedBusy else { return }
        archive = nil; storedMessage = nil
        do {
            guard let saved = try store.read() else { storedStatus = .consentRequired; return }
            guard saved.identity == access.identity else { storedStatus = .anotherAccount; return }
            archive = saved; storedStatus = .ready
        } catch { storedStatus = .unavailable; storedMessage = PersonalHealthFailure.storage.localizedDescription }
    }

    public func enroll(confirmedOwnHealth: Bool) {
        guard readable, importPermitted(), !storedBusy, storedStatus == .consentRequired else { return }
        guard confirmedOwnHealth else { storedMessage = PersonalHealthFailure.confirmation.localizedDescription; return }
        do {
            archive = try store.enroll(identity: access.identity, at: now())
            storedStatus = .ready; storedMessage = "This device’s Health history is linked to your personal account. Choose Read Health to request access."
        } catch { restore(); storedMessage = PersonalHealthFailure.storage.localizedDescription }
    }

    public func importHistory(requestPermission: Bool = true) async {
        guard mayImport, var saved = archive, requestPermission || saved.permissionRequested else { return }
        let identifier = UUID(); operation = identifier; storedBusy = true; storedMessage = nil
        lastAttempt = now()
        defer { if operation == identifier { storedBusy = false; historyTask = nil } }
        do {
            if requestPermission {
                try await authorizeHistory()
                try check(identifier)
                saved.permissionRequested = true
                saved = try store.update(saved, expectedRevision: saved.revision)
                archive = saved
            }
            let reading = Task { try await readHistory() }
            historyTask = reading
            let history = try await withTaskCancellationHandler(operation: { try await reading.value }, onCancel: { reading.cancel() })
            try check(identifier)
            guard history.importedAt <= now().addingTimeInterval(60) else { throw PersonalHealthFailure.invalid }
            saved.history = history
            if !history.sources.contains(where: { $0.id == saved.selectedSource }) { saved.selectedSource = history.sources.first?.id }
            archive = try store.update(saved, expectedRevision: saved.revision)
            storedMessage = history.sources.isEmpty
                ? "No readable sleep records were returned. This can mean no records or no permission; Apple Health does not distinguish them."
                : "Health history refreshed privately on this device. Sources stay separate. Nothing was sent to the Pod or an AI provider."
        } catch {
            guard readable, operation == identifier else { return }
            if error as? PersonalHealthFailure == .changed { archive = nil; storedStatus = .unavailable }
            storedMessage = error is CancellationError ? "Import cancelled. Your previous history is unchanged."
                : "Health could not be refreshed. Your previous history is unchanged. Reopen this page and review Health access before trying again."
        }
    }

    public func selectSource(_ identifier: String) {
        guard readable, !storedBusy, var saved = archive, saved.history?.sources.contains(where: { $0.id == identifier }) == true else { return }
        saved.selectedSource = identifier
        save(saved)
    }

    public func setAutomaticRefresh(_ enabled: Bool) {
        guard readable, !storedBusy, var saved = archive, !enabled || saved.permissionRequested else { return }
        saved.automaticRefresh = enabled
        save(saved)
    }

    public func refreshOnActivation() async {
        restore()
        guard let saved = archive, HealthHistoryRefreshPolicy.shouldRefresh(now: now(),
            importedAt: saved.history?.importedAt ?? .distantPast, lastAttempt: lastAttempt,
            enabled: saved.automaticRefresh, requested: saved.permissionRequested) else { return }
        await importHistory(requestPermission: false)
    }

    public func forget() {
        guard readable, let saved = archive else { return }
        cancelImport()
        do {
            try store.remove(identity: access.identity, expectedRevision: saved.revision)
            archive = nil; storedStatus = .consentRequired
            storedMessage = "This personal Health import and its device link were removed. Apple Health and the existing owner workspace are unchanged."
        } catch { archive = nil; storedStatus = .unavailable; storedMessage = PersonalHealthFailure.storage.localizedDescription }
    }

    public func invalidate() {
        cancelImport(); invalidated = true; archive = nil; storedMessage = nil
    }

    public func cancelImport() {
        let wasBusy = storedBusy
        operation = UUID(); historyTask?.cancel(); historyTask = nil; storedBusy = false
        if wasBusy { storedMessage = "Import cancelled. Your previous history is unchanged." }
    }

    /// Revocation deletes only this identity's local import; it never clears the retained owner archive.
    public static func removeLocalData(for identity: PersonalHealthIdentity, snapshots: PrivateSnapshotStore? = nil) throws {
        let store = PersonalHealthStore(snapshots: snapshots ?? .init(namespace: "personal-health-v1"))
        if let saved = try store.read(), saved.identity == identity {
            try store.remove(identity: identity, expectedRevision: saved.revision)
        }
    }

    /// Used only by the explicit "erase personal local data" flow, including an unreadable enrollment.
    public static func eraseAllLocalData(snapshots: PrivateSnapshotStore? = nil) throws {
        try PersonalHealthStore(snapshots: snapshots ?? .init(namespace: "personal-health-v1")).removeAll()
    }

    private func check(_ identifier: UUID) throws {
        try Task.checkCancellation()
        guard readable, importPermitted(), operation == identifier else { throw PersonalHealthFailure.changed }
    }
    private func save(_ saved: PersonalHealthArchive) {
        do { archive = try store.update(saved, expectedRevision: saved.revision); storedMessage = nil }
        catch { archive = nil; storedStatus = .unavailable; storedMessage = PersonalHealthFailure.storage.localizedDescription }
    }
}
