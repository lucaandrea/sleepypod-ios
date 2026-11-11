import CryptoKit
import Foundation
import FreeSleepKit
import Observation

/// Tracks one app-owned alarm. Persist its ID before asking iOS, so an interrupted
/// request can be inspected/cancelled later instead of creating a duplicate.
@MainActor @Observable final class BackupAlarmCoordinator {
    static let shared = BackupAlarmCoordinator(client: SystemBackupAlarmClient())
    private(set) var record: BackupAlarmRecord?
    private(set) var systemState: String?
    private(set) var checkedAt: Date?
    private(set) var busy = false
    private(set) var message: String?
    private let client: any BackupAlarmClient
    private let currentOwner: @MainActor () -> String?
    private let read: () throws -> BackupAlarmRecord?
    private let persist: (BackupAlarmRecord?) throws -> Void
    private let now: () -> Date

    init(client: any BackupAlarmClient, owner: @escaping @MainActor () -> String? = BackupAlarmCoordinator.ownerScope,
         read: (() throws -> BackupAlarmRecord?)? = nil,
         persist: ((BackupAlarmRecord?) throws -> Void)? = nil, now: @escaping () -> Date = Date.init) {
        self.client = client; currentOwner = owner; self.now = now
        let store = PrivateSnapshotStore(namespace: "wake-backup-v1")
        self.read = read ?? { try store.read(BackupAlarmRecord.self, scope: "this-device") }
        self.persist = persist ?? { value in
            if let value { try store.write(value, scope: "this-device") } else { try store.remove(scope: "this-device") }
        }
    }

    static func ownerScope() -> String? {
        guard APIBackend.current == .sleepypodCore, !PersonalWorkspaceBoundary.isActive else { return nil }
        let bytes = (try? JSONEncoder().encode(OwnerConnection.revision)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the operating system, not a cached successful scheduling response.
    func refresh() {
        guard !busy else { return }
        record = nil; systemState = nil; checkedAt = nil; message = nil
        do {
            guard let saved = try read() else { return }
            try saved.validate()
            guard saved.owner == currentOwner() else {
                try cancelStored(saved); message = "The previous connection's phone backup was removed."
                return
            }
            record = saved
            let actual = try client.alarms().first { $0.id == saved.id }
            systemState = actual?.at == saved.at ? actual?.state : actual == nil ? "missing" : "mismatch"
            checkedAt = now()
        } catch { message = "Could not verify the phone backup. " + error.localizedDescription }
    }

    func schedule(plan: NextAlarmState, receivedAt: Date?, expectedOwner: String?) async {
        guard !busy else { return }
        guard let owner = currentOwner(), owner == expectedOwner else {
            message = BackupAlarmFailure.changed.localizedDescription
            return
        }
        busy = true; message = nil; checkedAt = nil; systemState = nil
        defer { busy = false }
        var pendingRecord: BackupAlarmRecord?
        do {
            _ = try BackupAlarmPolicy.candidate(plan, receivedAt: receivedAt, now: now())
            guard try await client.requestAccess() else { throw BackupAlarmFailure.access }
            guard currentOwner() == owner, !Task.isCancelled else { throw BackupAlarmFailure.changed }
            let at = try BackupAlarmPolicy.candidate(plan, receivedAt: receivedAt, now: now())
            if let existing = try read() {
                try existing.validate()
                // Repeated taps reconcile the same occurrence without scheduling it twice.
                if existing.owner == owner, existing.side == plan.side, existing.at == at,
                   try client.alarms().contains(where: { $0.id == existing.id && $0.at == at && $0.state == "scheduled" }) {
                    record = existing; systemState = "scheduled"; checkedAt = now(); message = "This wake-up already has a phone backup."
                    return
                }
                try cancelStored(existing)
            }
            let pending = BackupAlarmRecord(version: 1, id: UUID(), owner: owner, side: plan.side,
                at: at, podRevision: plan.revision, createdAt: now())
            do { try persist(pending) } catch { throw BackupAlarmFailure.storage }
            record = pending; pendingRecord = pending
            try await client.schedule(id: pending.id, at: at)
            guard currentOwner() == owner, !Task.isCancelled else {
                try cancelStored(pending); record = nil
                throw BackupAlarmFailure.changed
            }
            let actual = try client.alarms().first { $0.id == pending.id }
            guard actual?.at == at, actual?.state == "scheduled" else { throw BackupAlarmFailure.invalid }
            systemState = "scheduled"; checkedAt = now()
            message = "iOS confirms this one-time backup. It has not been physically tested."
        } catch {
            if currentOwner() != owner || Task.isCancelled {
                record = nil
                if let pendingRecord {
                    do { try cancelStored(pendingRecord) }
                    catch {
                        message = "The connection changed during scheduling. Cancellation is not confirmed; check the phone backup again."
                        return
                    }
                }
            }
            message = error.localizedDescription + " Refresh to inspect the saved result; requests are not retried automatically."
        }
    }

    func cancel() {
        guard !busy else { return }
        busy = true; message = nil; systemState = nil; checkedAt = nil
        defer { busy = false }
        do {
            if let saved = try read() { try saved.validate(); try cancelStored(saved) }
            record = nil; message = "Phone backup removed. Your Pod alarm is unchanged."
        } catch { message = "Cancellation is not confirmed. " + error.localizedDescription }
    }

    private func cancelStored(_ saved: BackupAlarmRecord) throws {
        if try client.alarms().contains(where: { $0.id == saved.id }) { try client.cancel(id: saved.id) }
        guard try !client.alarms().contains(where: { $0.id == saved.id }) else { throw BackupAlarmFailure.invalid }
        try persist(nil)
    }
}
