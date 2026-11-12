import Foundation
import WidgetKit

/// Refreshes only from the active identity. A slow response from an old account cannot repopulate a widget.
@MainActor final class BedWidgetSession {
    private let source: any BedRemoteSource
    private let store: BedWidgetStore
    private let now: () -> Date
    private let reload: () -> Void
    private var generation = 0

    init(source: any BedRemoteSource, store: BedWidgetStore = .shared,
         now: @escaping () -> Date = Date.init,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: BedWidgetStore.kind) }) {
        self.source = source; self.store = store; self.now = now; self.reload = reload
        withdraw()
    }
    func withdraw() {
        generation += 1
        try? store.clear()
        reload()
    }
    func refresh() async {
        generation += 1
        let operation = generation
        do {
            try source.prepareRead()
            let expected = source.context
            let reading = try await source.read()
            try Task.checkCancellation()
            guard operation == generation else { return }
            guard expected == source.context, reading.context == expected else { withdraw(); return }
            try reading.snapshot.validate()
            let current = now()
            guard reading.snapshot.isCurrent(at: current), reading.snapshot.readingsFresh(at: current) else {
                withdraw(); return
            }
            let snapshot = BedWidgetSnapshot(version: 1, assignment: reading.snapshot.assignment,
                zones: reading.snapshot.zones.map { .init(id: $0.id, requestedF: $0.requestedF, powered: $0.powered) },
                nextWake: reading.snapshot.nextAlarm, checkedAt: reading.snapshot.receivedAt,
                wake: reading.snapshot.wake)
            try store.save(snapshot, at: current)
            reload()
        } catch {
            // Authentication and transport failures both withdraw; no previous person's status is retained.
            if operation == generation { withdraw() }
        }
    }
}
