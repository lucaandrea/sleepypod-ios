import Foundation
import Observation

/// This reader has no network client or actuator API. Reconnecting never replays its contents.
@MainActor @Observable final class PersonalOfflineLibraryWorkspace {
    let connection: PersonalBedConnection
    private(set) var library: PersonalOfflineLibrary?
    private(set) var error: String?
    private(set) var invalidated = false
    private let store: PersonalOfflineLibraryStore
    private let permitted: () -> Bool
    private let now: () -> Int64

    init(connection: PersonalBedConnection, store: PersonalOfflineLibraryStore,
         permitted: @escaping () -> Bool, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.connection = connection; self.store = store; self.permitted = permitted; self.now = now
    }
    var enabled: Bool { !invalidated && permitted() }
    func restore() {
        guard enabled else { library = nil; return }
        do { library = try store.read(connection: connection, now: now()); error = nil }
        catch { library = nil; self.error = "Saved readings are unavailable. Unlock this device or reconnect to refresh them." }
    }
    func save(_ page: PersonalHistoryPage, appending: Bool) {
        guard enabled else { return }
        do { try store.save(page, appending: appending, connection: connection, receivedAt: now()); restore() }
        catch { self.error = "These recordings could not be saved for offline reading. The previous saved copy has not been updated." }
    }
    func save(_ review: PersonalRoutineReview, temperatureUnit: String = "F") {
        guard enabled else { return }
        do { try store.save(review, connection: connection, receivedAt: now(), temperatureUnit: temperatureUnit); restore() }
        catch { self.error = "The operating week could not be saved for offline reading. The previous saved copy has not been updated." }
    }
    func remove() {
        guard enabled else { return }
        do { try store.remove(connection: connection); library = nil; error = nil }
        catch { self.error = "The saved copy could not be removed. Unlock this device and try again." }
    }
    func invalidate() { invalidated = true; library = nil; error = nil }
}
