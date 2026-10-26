import Foundation
import Observation

@MainActor @Observable
final class BaseWorkspace {
    private let api: (any BaseClient)?
    private let now: () -> Date
    let demo: Bool
    private(set) var status: UnifiedBaseStatus?
    private(set) var receivedAt = Date.distantPast
    private(set) var refreshError: String?
    private(set) var notice: String?
    private(set) var commandError: String?
    private(set) var sending = false
    private(set) var stopping = false
    private(set) var reconnecting = false
    private(set) var schedules: [BaseSchedule] = []
    private(set) var schedulesLoaded = false
    private(set) var scheduleError: String?
    private(set) var savingSchedule = false
    private(set) var targets = BasePositions.flat
    var previewRequested = false
    var speed = 50
    private var refreshRevision = 0
    private var commandRevision = 0
    private var scheduleRevision = 0

    init(api: (any BaseClient)? = nil, demo: Bool = false, now: @escaping () -> Date = { .now }) {
        self.demo = demo; self.now = now
        if let api { self.api = api }
        else if demo { self.api = DemoBaseClient(scenario: DebugRoute.baseScenario) }
        else { self.api = (try? CoreRESTClient.configured()).map { CoreBaseClient(client: $0) } }
    }
    var independent: Bool { status?.independentControl == true }
    var fresh: Bool { status?.stale == false && now().timeIntervalSince(receivedAt) < 10 && refreshError == nil }
    var measured: BasePositions? {
        guard fresh, status?.state == "connected", status?.position?.left.valid == true, status?.position?.right.valid == true else { return nil }
        return status?.position
    }
    var busy: Bool { sending || stopping || reconnecting || status?.busy == true }
    var readiness: String {
        if let refreshError { return refreshError }
        if let error = status?.error { return error }
        if status?.state == "unconfigured" { return "Complete base setup in the stock app, then reconnect." }
        if measured == nil { return "Waiting for a current position from the base." }
        return independent ? "Each side can move independently." : "This base moves both sides together."
    }
    func effectiveScope(_ requested: BaseScope, linked: Bool = false) -> BaseScope {
        independent && !linked ? requested : .both
    }
    func edit(_ angles: BaseAngles, scope: BaseScope, linked: Bool = false) {
        guard angles.valid else { return }
        targets[effectiveScope(scope, linked: linked)] = angles
        previewRequested = true
    }
    func matchDrafts() { targets.right = targets.left }
    func atTarget(_ scope: BaseScope) -> Bool {
        guard let measured else { return false }
        let selected = effectiveScope(scope)
        let target = targets[selected]
        return selected.sides.allSatisfy { measured[BaseScope(rawValue: $0)!] == target }
    }
    func canMove(_ scope: BaseScope) -> Bool {
        measured != nil && status?.ready == true && !busy && status?.isMoving(effectiveScope(scope)) != true
            && !atTarget(scope) && targets[effectiveScope(scope)].valid && (30...100).contains(speed)
    }
    func refresh() async {
        refreshRevision += 1
        let revision = refreshRevision
        do {
            guard let api else { throw APIError.noBaseURL }
            let result = try await api.status()
            guard revision == refreshRevision, !Task.isCancelled else { return }
            status = result; receivedAt = now(); refreshError = nil
        } catch {
            guard revision == refreshRevision, !Task.isCancelled else { return }
            refreshError = error.localizedDescription
        }
    }
    func selectPreset(_ preset: BasePreset, scope: BaseScope, linked: Bool, immediately: Bool) async {
        let selected = effectiveScope(scope, linked: linked)
        edit(preset.angles, scope: selected)
        if immediately { await move(selected) }
    }
    func move(_ requested: BaseScope) async {
        let scope = effectiveScope(requested)
        guard let api, canMove(scope) else { return }
        commandRevision += 1
        let revision = commandRevision
        let request = BaseMoveRequest(angles: targets[scope], speed: speed, scope: scope)
        sending = true; commandError = nil; notice = nil
        defer { sending = false }
        do {
            try await api.move(request)
            guard revision == commandRevision else { return }
            notice = demo ? "Simulated position updated." : "Move accepted. Measured angles update as the bed moves."
            previewRequested = false
            await refresh()
        } catch {
            guard revision == commandRevision else { return }
            commandError = "Movement not confirmed: \(error.localizedDescription) Check the bed before retrying."
            await refresh()
        }
    }
    /// Stop bypasses readiness and an in-flight move; late move responses cannot replace its result.
    func stop() async {
        guard let api, !stopping else { return }
        commandRevision += 1
        let revision = commandRevision
        stopping = true; commandError = nil; notice = nil
        defer { stopping = false }
        do {
            try await api.stop()
            guard revision == commandRevision else { return }
            notice = demo ? "Simulation stopped." : "Stop acknowledged for both sides. Verify the bed has stopped."
            await refresh()
        } catch {
            guard revision == commandRevision else { return }
            commandError = "Stop was not acknowledged. Use the bed’s physical control. \(error.localizedDescription)"
        }
    }
    func reconnect() async {
        guard let api, !busy else { return }
        commandRevision += 1
        let revision = commandRevision
        reconnecting = true; commandError = nil; notice = nil
        defer { reconnecting = false }
        do {
            try await api.reconnect()
            if revision == commandRevision { await refresh() }
        } catch { if revision == commandRevision { commandError = error.localizedDescription } }
    }
    func loadSchedules() async {
        scheduleRevision += 1
        let revision = scheduleRevision
        do {
            guard let api else { throw APIError.noBaseURL }
            let result = try await api.schedules()
            guard revision == scheduleRevision, !Task.isCancelled else { return }
            schedules = result.sorted { $0.time < $1.time }; schedulesLoaded = true; scheduleError = nil
        } catch { if revision == scheduleRevision && !Task.isCancelled { scheduleError = error.localizedDescription } }
    }
    func validation(_ schedule: BaseSchedule) -> String? {
        if !schedule.valid { return "Choose a name, valid time, supported angles, and speed from 30–100%." }
        if schedule.side != .both && !independent { return "This base supports whole-bed movement only." }
        if schedules.contains(where: { schedule.conflicts(with: $0) }) {
            return "An adjustment already exists for this side at this day and time. Edit that adjustment instead."
        }
        return nil
    }
    @discardableResult func save(_ schedule: BaseSchedule) async -> Bool {
        guard let api, schedulesLoaded, !savingSchedule else { return false }
        if let error = validation(schedule) { scheduleError = error; return false }
        scheduleRevision += 1
        savingSchedule = true; scheduleError = nil
        defer { savingSchedule = false }
        do {
            let saved = try await api.save(schedule)
            schedules.removeAll { $0.id == saved.id }; schedules.append(saved); schedules.sort { $0.time < $1.time }
            return true
        } catch { scheduleError = error.localizedDescription; return false }
    }
    func remove(_ schedule: BaseSchedule) async {
        guard let api, let id = schedule.id, !savingSchedule else { return }
        scheduleRevision += 1
        savingSchedule = true; scheduleError = nil
        defer { savingSchedule = false }
        do { try await api.delete(id); schedules.removeAll { $0.id == id } }
        catch { scheduleError = error.localizedDescription }
    }
}
