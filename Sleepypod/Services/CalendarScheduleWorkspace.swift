import Foundation
import Observation

@MainActor @Observable final class CalendarScheduleWorkspace {
    private var client: (any CalendarScheduleClient)?
    private var generation = 0
    private(set) var rows: [Side: CoreScheduleRows] = [:]
    private(set) var errors: [Side: String] = [:]
    private(set) var saving = false
    private(set) var loading = false
    private(set) var notice: String?
    func configure(client: (any CalendarScheduleClient)?) { generation += 1; self.client = client; rows = [:]; errors = [:]; saving = false; loading = false; notice = nil }
    func invalidate() { generation += 1; rows = [:]; saving = false; loading = false; notice = nil }
    func load(_ sides: [Side]) async {
        guard !saving, !loading else { return }
        guard let client else {
            for side in sides { errors[side] = "Connect to a controller to load schedules." }
            return
        }
        let operation = generation; loading = true
        defer { if operation == generation { loading = false } }
        for side in sides {
            do {
                let loaded = try await client.rows(side: side)
                guard operation == generation, !Task.isCancelled else { return }
                try CalendarScheduleControl.validate(loaded, side: side)
                rows[side] = loaded; errors[side] = nil
            } catch { if operation == generation { errors[side] = error.localizedDescription; rows[side] = nil } }
        }
    }
    /// Recheck all rows before one batch; an uncertain result requires explicit reload, never replay.
    func apply(_ review: CalendarScheduleControl) async -> Bool {
        guard let client, !saving, !loading, rows[review.side] != nil, CalendarScheduleControl.hasRows(review.original) else { return false }
        saving = true; notice = nil; let operation = generation
        defer { if operation == generation { saving = false } }
        do {
            let latest = try await client.rows(side: review.side)
            guard operation == generation, !Task.isCancelled else { return false }
            try CalendarScheduleControl.validate(latest, side: review.side)
            guard CalendarScheduleControl.same(latest, review.original) else { throw APIError.serverError(message: "These schedules changed on another device. Reload and review them before changing all schedules.") }
            try await client.apply(review)
            let confirmed = try await client.rows(side: review.side)
            guard operation == generation else { return false }
            guard CalendarScheduleControl.same(confirmed, review.desired) else { throw APIError.serverError(message: "The returned schedules did not match the change. Reload before trying again.") }
            rows[review.side] = confirmed; errors[review.side] = nil
            notice = review.enabled ? "All schedules enabled for this side." : "All schedules paused for this side."
            return true
        } catch {
            if operation == generation { errors[review.side] = error.localizedDescription; rows[review.side] = nil }
            return false
        }
    }
}
