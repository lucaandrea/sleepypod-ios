import Foundation
import Observation

@MainActor @Observable final class BiometricReferencesWorkspace {
    let side: Side
    let client: any BiometricReferencesServing
    private let store: ReferencePendingStore
    private(set) var page: ReferenceLibraryPage?
    private(set) var cursor: ReferenceLibraryPage.Cursor?
    private(set) var previous: [ReferenceLibraryPage.Cursor?] = []
    private(set) var loading = false
    private(set) var loadError: String?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var pending: ReferencePending?
    private(set) var unreadable = false
    private(set) var canRetry = false
    private(set) var receipt: ReferenceDescriptor?
    private(set) var notice: String?
    var canMutate: Bool { !busy && pending == nil && !unreadable }
    init(side: Side, client: any BiometricReferencesServing, store: ReferencePendingStore) {
        self.side = side; self.client = client; self.store = store
        do { pending = try store.read(scope: client.scope, side: side) }
        catch { unreadable = true; self.error = "A retained reference request cannot be read. New writes are paused until you discard that local request. This does not undo a controller change." }
    }
    func load(_ next: ReferenceLibraryPage.Cursor? = nil, direction: Int = 0) async {
        guard !loading else { return }
        loading = true; loadError = nil
        defer { loading = false }
        do {
            let result = try await client.library(side: side, cursor: next)
            guard !Task.isCancelled else { return }
            guard result.items.allSatisfy({ $0.summary.side == side }) else { throw failure("The library returned references for another side.") }
            if direction > 0 { previous.append(cursor) }
            else if direction < 0 { _ = previous.popLast() }
            else if next == nil { previous = [] }
            page = result; cursor = next
        } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
    }
    func commit(_ request: ReferenceCommit) async {
        guard canMutate else { return }
        busy = true; error = nil; receipt = nil; notice = nil
        defer { busy = false }
        do {
            guard request.input.side == side else { throw failure("The reviewed import belongs to another side.") }
            _ = try request.input.validated()
            let retained = ReferencePending.commit(request)
            try store.write(retained, scope: client.scope, side: side); pending = retained; canRetry = false
            try await send(retained)
        } catch { self.error = error.localizedDescription }
        await load()
    }
    func delete(_ descriptor: ReferenceDescriptor) async {
        guard canMutate else { return }
        busy = true; error = nil; receipt = nil; notice = nil
        defer { busy = false }
        do {
            guard descriptor.summary.side == side, descriptor.available else { throw failure("This reference is unavailable or belongs to another side.") }
            let retained = ReferencePending.deletion(descriptor)
            try store.write(retained, scope: client.scope, side: side); pending = retained; canRetry = false
            try await send(retained)
        } catch { self.error = error.localizedDescription }
        await load()
    }
    /// Reconcile by exact identity and content. Reading never repeats a write.
    func inspectPending() async {
        guard !busy, let pending else { return }
        busy = true; error = nil; notice = nil; canRetry = false
        defer { busy = false }
        do { try await reconcile(pending) }
        catch { self.error = error.localizedDescription }
        await load()
    }
    func retry() async {
        guard !busy, canRetry, let pending else { return }
        busy = true; error = nil; notice = nil; canRetry = false
        defer { busy = false }
        do {
            try await reconcile(pending)
            if self.pending == pending, canRetry { canRetry = false; try await send(pending) }
        } catch { self.error = error.localizedDescription }
        await load()
    }
    func stopRetrying() {
        guard !busy else { return }
        do {
            if let pending { try store.remove(pending, scope: client.scope, side: side) }
            else if unreadable { try store.discardUnreadable(scope: client.scope, side: side) }
            pending = nil; unreadable = false; canRetry = false; error = nil
            notice = "Local retained request removed. Any controller change remains. Reload the library before preparing another import."
        } catch { self.error = error.localizedDescription }
    }
    private func requireCurrent(_ expected: ReferencePending) throws {
        guard try store.read(scope: client.scope, side: side) == expected else { throw failure("This request was removed or replaced in another workspace. Reopen References before continuing.") }
    }
    private func send(_ retained: ReferencePending) async throws {
        try requireCurrent(retained)
        switch retained {
        case .commit(let request):
            let result = try await client.commit(request)
            guard request.matches(result), result.available, UUID(uuidString: result.id) != nil else { throw failure("The save response does not match the reviewed import. Inspect the retained request.") }
            try finish(retained, result: result, message: result.alreadyImported == true ? "This exact import was already saved." : "Reference revision saved. This does not establish validation.")
        case .deletion(let descriptor):
            let current = try await client.descriptor(id: descriptor.id)
            guard current.id == descriptor.id, current.summary == descriptor.summary else { throw failure("The source identity changed. Reload before deleting.") }
            if !current.available { try finish(retained, result: current, message: "Source measurements are deleted. Frozen dataset copies remain separate."); return }
            try requireCurrent(retained)
            let result = try await client.delete(id: descriptor.id)
            guard result.id == descriptor.id, result.deletedAtMs != nil else { throw failure("The deletion response is incomplete. Inspect the retained request.") }
            let confirmed = try await client.descriptor(id: descriptor.id)
            guard confirmed.id == descriptor.id, confirmed.summary == descriptor.summary, !confirmed.available, confirmed.deletedAtMs != nil else { throw failure("Deletion has not been confirmed by the source descriptor.") }
            try finish(retained, result: confirmed, message: "Source measurements deleted. Frozen dataset copies remain separate.")
        }
    }
    private func finish(_ retained: ReferencePending, result: ReferenceDescriptor, message: String) throws {
        try store.remove(retained, scope: client.scope, side: side)
        pending = nil; canRetry = false; receipt = result; notice = message
    }
    private func reconcile(_ retained: ReferencePending) async throws {
        try requireCurrent(retained)
        switch retained {
        case .deletion(let original):
            let current = try await client.descriptor(id: original.id)
            guard current.id == original.id, current.summary == original.summary else { throw failure("The source identity no longer matches this deletion.") }
            if !current.available, current.deletedAtMs != nil { try finish(retained, result: current, message: "Deletion confirmed. Frozen dataset copies remain separate.") }
            else { canRetry = true; notice = "The source is still available. You can explicitly retry this exact deletion." }
        case .commit(let request):
            var next: ReferenceLibraryPage.Cursor?
            var visited: [ReferenceLibraryPage.Cursor] = []
            var foundDeleted = false
            repeat {
                try Task.checkCancellation()
                let result = try await client.library(side: side, cursor: next)
                guard result.items.allSatisfy({ $0.summary.side == side }) else { throw failure("The library returned another side. Retry remains paused.") }
                if let found = result.items.first(where: { request.matches($0) && $0.available }) {
                    try finish(retained, result: found, message: "The exact saved import was found. No write was repeated."); return
                }
                foundDeleted = foundDeleted || result.items.contains { request.matches($0) && !$0.available }
                next = result.nextCursor
                if let next {
                    guard !visited.contains(next), visited.count < 1000 else { throw failure("The complete library could not be inspected. Retry remains paused.") }
                    visited.append(next)
                }
            } while next != nil
            try requireCurrent(retained)
            guard !foundDeleted else { throw failure("An exact matching import was deleted. Retrying could recreate it. Stop retaining this request and review a new import if you intend to restore it.") }
            canRetry = true; notice = "No matching saved import was found. You can explicitly retry the exact reviewed import."
        }
    }
    private func failure(_ message: String) -> ReferenceTextError { .init(message: message) }
}
