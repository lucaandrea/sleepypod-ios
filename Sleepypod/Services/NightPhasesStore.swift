import Foundation
import Observation

/// Debounces phase edits per side, compares the original schedule, then reads back the result.
/// A failed or interrupted write never retries automatically or moves to another connection.
@MainActor @Observable final class NightPhasesStore {
    private(set) var phases: [Side: NightPhases] = [:]
    private(set) var errors: [Side: String] = [:]
    private(set) var saving: Set<Side> = []
    private(set) var saved: Set<Side> = []
    private(set) var unsupported = false
    private(set) var isLoading = false
    var error: String? { Side.allCases.compactMap { errors[$0] }.first }
    private var client: (any NightPhaseClient)?
    private var snapshots: [Side: NightPhaseSnapshot] = [:]
    private var pending: [Side: [NightPhaseKey: Int]] = [:]
    private var timers: [Side: Task<Void, Never>] = [:]
    private var blocked: Set<Side> = []
    private var generation = UUID()
    private var timezone = "America/Los_Angeles"
    private var endAction = ScheduleEndAction.turnOff
    private var clock: @Sendable () -> Date = { .now }
    private var delay: Duration = .milliseconds(700)

    func configure(client: (any NightPhaseClient)?, timezone: String, endAction: ScheduleEndAction = .turnOff,
                   clock: @escaping @Sendable () -> Date = { .now }, delay: Duration = .milliseconds(700)) {
        suspend(); self.client = client; self.timezone = timezone; self.endAction = endAction
        self.clock = clock; self.delay = delay; unsupported = client == nil
    }
    func suspend() {
        timers.values.forEach { $0.cancel() }; timers = [:]; generation = UUID()
        pending = [:]; snapshots = [:]; phases = [:]; errors = [:]; saving = []; saved = []; blocked = []; isLoading = false
    }
    func load(_ sides: [Side]) async {
        guard let client else { unsupported = true; return }
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        for side in sides where !saving.contains(side) {
            timers[side]?.cancel(); timers[side] = nil
            do {
                let rows = try await client.rows(side: side)
                guard token == generation, !Task.isCancelled else { return }
                let snapshot = try NightPhaseSnapshot.make(side: side, rows: rows, now: clock(), timezone: timezone)
                snapshots[side] = snapshot; phases[side] = snapshot.phases
                pending[side] = nil; errors[side] = nil; blocked.remove(side)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                phases[side] = nil; snapshots[side] = nil; blocked.insert(side)
                errors[side] = error.localizedDescription
            }
        }
    }
    func canEdit(_ side: Side) -> Bool { snapshots[side] != nil && !saving.contains(side) && !blocked.contains(side) && !isLoading }
    func value(_ side: Side, _ phase: NightPhaseKey) -> Int? {
        pending[side]?[phase] ?? phases[side]?.phase(phase).map { Int(floor($0.temperatureF + 0.5)) }
    }
    func nudge(_ sides: [Side], phase: NightPhaseKey, delta: Int, format: TemperatureFormat, display: TemperatureDisplay = .degrees) {
        guard sides.allSatisfy(canEdit) else { return }
        for side in sides {
            guard let value = value(side, phase) else { continue }
            saved.remove(side)
            pending[side, default: [:]][phase] = display.step(value, by: delta, unit: format)
            timers[side]?.cancel()
            let token = generation, delay = delay
            timers[side] = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, token == self.generation else { return }
                await self.commit(side: side, token: token)
            }
        }
    }
    static func step(_ tempF: Int, delta: Int, format: TemperatureFormat) -> Int {
        TemperatureDisplay.degrees.step(tempF, by: delta, unit: format)
    }
    private func commit(side: Side, token: UUID) async {
        guard let client, let snapshot = snapshots[side], let targets = pending[side], canEdit(side) else { return }
        timers[side] = nil; saving.insert(side)
        defer { if token == generation { saving.remove(side) } }
        do {
            let latest = try await client.rows(side: side)
            guard token == generation else { return }; try Task.checkCancellation()
            let batch = try snapshot.batch(latest: latest, targets: targets, now: clock(), timezone: timezone, endAction: endAction)
            if !batch.isEmpty { try await client.apply(batch) }
            guard token == generation else { return }; try Task.checkCancellation()
            let readback = try await client.rows(side: side)
            guard token == generation else { return }; try Task.checkCancellation()
            guard batch.matches(readback, side: side) else { throw APIError.serverError(message: "The saved schedule did not match the requested temperatures.") }
            let updated = try NightPhaseSnapshot.make(side: side, rows: readback, now: clock(), timezone: timezone)
            snapshots[side] = updated; phases[side] = updated.phases; pending[side] = nil; errors[side] = nil; saved.insert(side)
        } catch {
            guard token == generation else { return }
            blocked.insert(side)
            errors[side] = "\(error.localizedDescription) Your adjustment has not been confirmed. Reload before editing again."
        }
    }
}
