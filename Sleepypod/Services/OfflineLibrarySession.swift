import Foundation
import FreeSleepKit
import Observation

/// A read-only library, never a command queue or an authority for new writes.
@MainActor @Observable final class OfflineLibrarySession {
    private var savedLibrary = OfflineLibrary()
    var library: OfflineLibrary { scope != nil && scope == currentScope() ? savedLibrary : .init() }
    private(set) var error: String?
    private(set) var refreshing = false
    private var scope: String?
    private var generation = 0
    private var restored = false
    private let store: PrivateSnapshotStore
    private let currentScope: () -> String?
    private let now: () -> Date

    init(store: PrivateSnapshotStore = .init(namespace: "owner-library-v1"),
         currentScope: @escaping () -> String? = { OfflineLibrarySession.ownerScope },
         now: @escaping () -> Date = Date.init) {
        self.store = store; self.currentScope = currentScope; self.now = now
    }

    static var ownerScope: String? {
        guard !PersonalWorkspaceBoundary.isActive, !APIBackend.current.isDemo,
              !OwnerConnection.displayAddress.isEmpty else { return nil }
        return OwnerDataIdentity.current.offlineLibraryScope
    }

    func restore() {
        let next = currentScope()
        guard scope != next || !restored else { return }
        generation += 1; scope = next; savedLibrary = .init(); error = nil; refreshing = false; restored = false
        guard let next else { return }
        do {
            if let saved = try store.read(OfflineLibrary.self, scope: next), saved.version == 1 { savedLibrary = saved }
            restored = true
        } catch { self.error = "Saved records are unavailable. Reconnect to refresh this device’s private copy." }
    }

    func withdraw() { generation += 1; scope = nil; savedLibrary = .init(); error = nil; refreshing = false; restored = false }

    func erase() {
        generation += 1; refreshing = false
        guard let scope, scope == currentScope() else { withdraw(); return }
        savedLibrary = .init()
        do { try store.remove(scope: scope); error = nil }
        catch { self.error = "The saved copy could not be removed. Please try again." }
    }

    /// Refresh independently so one unavailable source cannot relabel older data as fresh.
    func refresh(client: any SleepypodProtocol, timeZone: String) async {
        restore()
        guard let scope, !refreshing else { return }
        refreshing = true; error = nil
        let operation = generation, end = now()
        let start = end.addingTimeInterval(-30 * 86_400)
        defer { if operation == generation { refreshing = false } }
        for section in 0..<3 {
            guard valid(operation, scope) else { return }
            do {
                if section == 0 {
                    let received = try await client.getSchedules()
                    guard valid(operation, scope) else { return }
                    savedLibrary.schedules = .init(savedAt: now(), value: received)
                } else {
                    let side: Side = section == 1 ? .left : .right
                    let received = try await client.getSleepRecords(side: side, start: start, end: end)
                    guard valid(operation, scope) else { return }
                    let reading = OfflineReading(savedAt: now(), value: received.filter {
                        $0.side == side.rawValue && $0.enteredBedDate >= start && $0.enteredBedDate <= end
                    })
                    if side == .left { savedLibrary.left = reading } else { savedLibrary.right = reading }
                }
                savedLibrary.timeZone = timeZone
                try store.write(savedLibrary, scope: scope)
            } catch {
                guard valid(operation, scope) else { return }
                if case APIError.invalidResponse(let code) = error, code == 401 || code == 403 {
                    erase()
                    self.error = "This Pod no longer authorizes the saved connection. Reconnect with a valid account."
                    return
                }
                self.error = "Some saved sections could not be refreshed. Check each section’s last sync time."
            }
        }
    }

    private func valid(_ operation: Int, _ expectedScope: String) -> Bool {
        operation == generation && scope == expectedScope && currentScope() == expectedScope && !Task.isCancelled
    }
}
