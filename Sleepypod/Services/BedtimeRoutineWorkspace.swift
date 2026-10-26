import Foundation
import Observation

@MainActor @Observable final class BedtimeRoutineWorkspace {
    private var client: (any BedtimeRoutineClient)?
    private var generation = 0
    private(set) var side: Side = .left
    private(set) var book: BedtimeRoutineBook?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var requiresReload = false

    func configure(client: (any BedtimeRoutineClient)?, side: Side) {
        generation += 1; self.client = client; self.side = side
        book = nil; busy = false; error = nil; notice = nil; requiresReload = false
    }
    func invalidate() { generation += 1; book = nil; busy = false }
    func load() async {
        guard !busy else { return }
        guard let client else { error = "Connect to a controller to read bedtime routines."; return }
        let operation = generation, owner = OwnerConnection.revision, selectedSide = side
        busy = true; defer { if operation == generation { busy = false } }
        do {
            let result = try await client.routines(side: selectedSide); try result.validate(side: selectedSide)
            guard operation == generation, owner == OwnerConnection.revision, !Task.isCancelled else { return }
            book = result; error = nil; requiresReload = false
        } catch { if operation == generation { book = nil; self.error = error.localizedDescription } }
    }
    /// All target revisions travel in one atomic request; an unknown save is only recovered by reading.
    func save(_ changes: BedtimeRoutineChanges) async -> Bool {
        guard !busy, !requiresReload, let client, let book, changes.side == side else { return false }
        let operation = generation, owner = OwnerConnection.revision, selectedSide = side
        busy = true; notice = nil; defer { if operation == generation { busy = false } }
        do {
            try changes.validate(against: book)
            let current = try await client.routines(side: selectedSide); try changes.validate(against: current)
            guard operation == generation, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
            let result = try await client.replace(changes); try result.book.validate(side: selectedSide)
            guard operation == generation, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
            for change in changes.changes {
                let saved = result.routines.first { $0.dayOfWeek == change.dayOfWeek }
                guard saved?.draft.normalized == change.replacement?.normalized else {
                    throw BedtimeRoutineTime.error("The saved routine does not match the reviewed draft. Reload before editing again.")
                }
            }
            self.book = result.book; error = nil
            notice = result.schedulerApplied
                ? "Routines saved and scheduler updated."
                : "Routines saved. The scheduler has not confirmed the update. Check System → Scheduler before relying on these times."
            return true
        } catch {
            if operation == generation { self.error = error.localizedDescription + " Close the editor and reload before trying again."; self.book = nil; requiresReload = true }
            return false
        }
    }
}
