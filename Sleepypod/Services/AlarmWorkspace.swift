import Foundation
import Observation

@Observable @MainActor
final class AlarmWorkspace {
    private(set) var rows: [CoreAlarmRow] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var saving = false
    private(set) var testing = false
    private(set) var stopping = false
    private(set) var testingSides: Set<Side> = []
    var error: String?
    var commandError: String?
    var notice: String?
    private(set) var demo: Bool
    private var api: any AlarmClient
    private var revision = 0
    private var commandRevision = 0
    private var schemaSnooze = false

    init(api: (any AlarmClient)? = nil, demo: Bool = APIBackend.current.isDemo) {
        self.demo = demo; self.api = api ?? (demo ? DemoAlarmClient() : CoreAlarmClient())
    }
    func configure(api: (any AlarmClient)? = nil, demo: Bool = APIBackend.current.isDemo) {
        revision += 1; commandRevision += 1
        self.demo = demo; self.api = api ?? (demo ? DemoAlarmClient() : CoreAlarmClient())
        rows = []; loaded = false; loading = false; saving = false; testing = false; stopping = false
        error = nil; commandError = nil; notice = nil; testingSides = []
        schemaSnooze = false
    }
    var supportsSnooze: Bool { demo || schemaSnooze || rows.contains { $0.snoozeDuration != nil && $0.snoozeTaper != nil } }
    func groups(_ side: Side) -> [AlarmGroup] { AlarmGroup.group(rows, side: side) }
    func nextGroup(_ side: Side, now: Date, timeZone: TimeZone) -> AlarmGroup? {
        let groups = groups(side)
        guard loaded else { return nil }
        return groups.compactMap { group in group.nextDate(after: now, timeZone: timeZone).map { (group, $0) } }
            .min { $0.1 < $1.1 }?.0 ?? groups.first
    }
    func refresh() async {
        guard !loading, !saving else { return }
        loading = true; revision += 1; let operation = revision; let client = api
        do {
            let current = try await client.all()
            guard revision == operation else { return }
            var supportsSnooze = current.contains { $0.snoozeDuration != nil && $0.snoozeTaper != nil }
            if !supportsSnooze { supportsSnooze = await client.supportsSnooze() }
            guard revision == operation else { return }
            rows = current; schemaSnooze = supportsSnooze; loaded = true; error = nil
        } catch { if revision == operation { loaded = false; self.error = APIError.message(for: error) } }
        if revision == operation { loading = false }
    }
    func save(_ draft: AlarmDraft) async -> Bool {
        if let problem = draft.validation { error = problem; return false }
        let creates = draft.creates.map { row in
            var result = row
            if !supportsSnooze { result.snoozeDuration = nil; result.snoozeTaper = nil }
            return result
        }
        return await mutate(AlarmBatch(creates: creates, deletes: draft.original.map(\.id)), expected: draft.original)
    }
    func toggle(_ group: AlarmGroup, enabled: Bool) async {
        _ = await mutate(AlarmBatch(updates: group.rows.map { AlarmToggle(id: $0.id, enabled: enabled) }), expected: group.rows)
    }
    func delete(_ group: AlarmGroup) async -> Bool {
        await mutate(AlarmBatch(deletes: group.rows.map(\.id)), expected: group.rows)
    }

    /// Recheck the editor's source rows, then send one atomic batch without touching other alarms.
    private func mutate(_ batch: AlarmBatch, expected: [CoreAlarmRow]) async -> Bool {
        guard loaded, !saving else { return false }
        saving = true; error = nil; revision += 1; let operation = revision; let client = api
        defer { if revision == operation { saving = false; loading = false } }
        var attempted = false
        do {
            let latest = try await client.all()
            guard revision == operation else { return false }
            guard expected.allSatisfy({ original in latest.contains(original) }) else {
                rows = latest
                throw APIError.serverError(message: "This alarm changed on another device. Cancel and reopen it to review the latest settings.")
            }
            attempted = true
            try await client.apply(batch)
            guard revision == operation else { return false }
            do {
                let refreshed = try await client.all()
                guard revision == operation else { return true }
                rows = refreshed; loaded = true
            }
            catch { if revision == operation { loaded = false; self.error = "Saved, but the alarm list could not be refreshed. Reload before making another change." } }
            return true
        } catch {
            if revision == operation {
                loaded = false
                self.error = attempted ? "The alarm change could not be confirmed. Reload before making another change." : APIError.message(for: error)
            }
            return false
        }
    }
    func test(_ draft: AlarmDraft) async {
        guard loaded, !testing, !stopping, !draft.sides.isEmpty, (1...100).contains(draft.intensity), (0...180).contains(draft.duration) else { return }
        testing = true; commandError = nil; commandRevision += 1; let operation = commandRevision; let client = api
        for side in Side.allCases where draft.sides.contains(side) {
            guard operation == commandRevision else { break }
            testingSides.insert(side)
            do { try await client.test(AlarmJob(side: side, vibrationIntensity: draft.intensity, vibrationPattern: draft.pattern, duration: draft.duration)) }
            catch { if operation == commandRevision { commandError = APIError.message(for: error) }; break }
        }
        if operation == commandRevision {
            testing = false
            if commandError == nil { notice = demo ? "Vibration test simulated." : "Vibration test sent. It stops after \(draft.duration) seconds." }
        }
    }
    func stopTest() async {
        guard !stopping else { return }
        commandRevision += 1; let operation = commandRevision; let client = api; let targets = testingSides
        stopping = true; testing = false; commandError = nil
        for side in Side.allCases where targets.contains(side) {
            do { try await client.stop(side); if operation == commandRevision { testingSides.remove(side) } }
            catch { if operation == commandRevision { commandError = APIError.message(for: error) } }
        }
        if operation == commandRevision { stopping = false; if commandError == nil { notice = "Vibration test stopped." } }
    }
}
