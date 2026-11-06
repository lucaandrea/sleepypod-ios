import Foundation
import Observation

@MainActor @Observable
final class HealthHRVReviewWorkspace {
    static let batchSize = 200
    private(set) var entries: [HealthHRVEntry] = []
    private(set) var retainedSDNN = 0
    private(set) var scope: HealthHRVScope?
    private(set) var busy = false
    private(set) var removedCount = 0
    private(set) var error: String?
    var selected = Set<UUID>()
    @ObservationIgnored var context: @MainActor () -> [String]? = { nil }
    private let store: any HealthHRVReviewStore
    private var reviewContext: [String]?
    private var generation = UUID()

    init(store: any HealthHRVReviewStore = SystemHealthHRVReviewStore()) { self.store = store }

    func clear() {
        generation = UUID()
        entries = []; selected = []; scope = nil; retainedSDNN = 0; reviewContext = nil; error = nil
    }

    func read(scope requestedScope: HealthHRVScope) async {
        guard !busy else { return }
        clear(); removedCount = 0
        guard requestedScope.isValid, let original = context() else { error = HealthHRVReviewError.unavailable.localizedDescription; return }
        let operation = generation
        busy = true; defer { busy = false }
        do {
            try await store.authorize()
            try check(operation, original)
            let records = try await store.read(requestedScope)
            try check(operation, original)
            let own = records.filter { requestedScope.contains($0) }
            guard Set(own.map(\.id)).count == own.count else { throw HealthHRVReviewError.changed }
            entries = own.filter { !$0.hasRecordedSDNN }.sorted(by: Self.ordered)
            retainedSDNN = own.count - entries.count
            scope = requestedScope; reviewContext = original
        } catch {
            if operation == generation { self.error = error.localizedDescription }
        }
    }

    /// Delete only the reviewed selection. A fresh read catches changed/deleted samples before any batch.
    func removeSelected() async {
        guard !busy else { return }
        error = nil; removedCount = 0
        guard let scope, let original = reviewContext, context() == original else { error = HealthHRVReviewError.changed.localizedDescription; return }
        let chosen = entries.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, chosen.count == selected.count else { error = HealthHRVReviewError.selection.localizedDescription; return }
        let operation = generation
        busy = true; defer { busy = false }
        do {
            try check(operation, original)
            let fresh = try await store.read(scope).filter { selected.contains($0.id) }.sorted(by: Self.ordered)
            try check(operation, original)
            guard fresh == chosen else { throw HealthHRVReviewError.changed }
            for offset in stride(from: 0, to: chosen.count, by: Self.batchSize) {
                try check(operation, original)
                let batch = Array(chosen[offset..<min(chosen.count, offset + Self.batchSize)])
                try await store.remove(batch, scope: scope) { try self.check(operation, original) }
                removedCount += batch.count
                let identifiers = Set(batch.map(\.id))
                entries.removeAll { identifiers.contains($0.id) }; selected.subtract(identifiers)
                try check(operation, original)
            }
        } catch {
            if operation == generation { self.error = error.localizedDescription }
            // Any failure needs a new read and a new selection; never silently retry a destructive action.
            selected = []; reviewContext = nil
        }
    }

    private func check(_ operation: UUID, _ original: [String]) throws {
        try Task.checkCancellation()
        guard operation == generation, context() == original else { throw HealthHRVReviewError.changed }
    }

    private static func ordered(_ first: HealthHRVEntry, _ second: HealthHRVEntry) -> Bool {
        first.start == second.start ? first.id.uuidString < second.id.uuidString : first.start < second.start
    }
}
