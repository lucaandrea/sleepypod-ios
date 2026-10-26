import Foundation
import Observation

@Observable @MainActor
final class CurveWorkspace {
    private(set) var curves: [PodCurve] = []
    private(set) var supportsAssignments = false
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var saving = false
    private(set) var sessions: [Side: RunOnceSession] = [:]
    var error: String?
    var notice: String?
    private var api: any CurveClient
    private var revision = 0
    init(api: (any CurveClient)? = nil, demo: Bool = APIBackend.current.isDemo) {
        self.api = api ?? (demo ? DemoCurveClient() : CoreCurveClient())
    }
    func configure(api: (any CurveClient)? = nil, demo: Bool = APIBackend.current.isDemo) {
        revision += 1; self.api = api ?? (demo ? DemoCurveClient() : CoreCurveClient())
        curves = []; sessions = [:]; loaded = false; loading = false; saving = false; error = nil; notice = nil
        supportsAssignments = false
    }
    func refresh() async {
        guard !saving, !loading else { return }
        loading = true; revision += 1; let operation = revision; let client = api
        defer { if revision == operation { loading = false } }
        do {
            let snapshot = try await client.library()
            guard revision == operation else { return }
            curves = snapshot.curves; supportsAssignments = snapshot.supportsAssignments; loaded = true; error = nil
            for side in Side.allCases {
                let session = try await client.active(side)
                guard revision == operation else { return }; sessions[side] = session
            }
        } catch { if revision == operation { self.error = error.localizedDescription } }
    }
    func moves(_ draft: CurveDraft) -> [CurveMove] { CurveMove.preview(draft, among: curves) }
    func save(_ draft: CurveDraft, reviewed: [CurveMove]) async -> Bool {
        if let validation = draft.validation { error = validation; return false }
        return await change { client, operation in
            let latest = try await client.library()
            guard self.revision == operation else { throw CancellationError() }
            try Self.checkOriginal(draft.original, latest: latest.curves)
            guard CurveMove.preview(draft, among: latest.curves) == reviewed else {
                throw APIError.serverError(message: "The days assigned to other curves changed. Reload and review the moves before saving.")
            }
            if !latest.supportsAssignments, let original = draft.original, original.name != draft.name {
                throw APIError.serverError(message: "This controller saves curves by name. Duplicate the curve to give it a new name.")
            }
            let changed = try await client.put(draft.payload, assignments: latest.supportsAssignments)
            return changed.moved.isEmpty ? "Curve saved." : "Curve saved. Shared days moved to this curve."
        }
    }
    func delete(_ curve: PodCurve) async -> Bool {
        await change { client, operation in
            let latest = try await client.library(); try Self.checkOriginal(curve, latest: latest.curves)
            guard self.revision == operation else { throw CancellationError() }
            try await client.delete(curve); return "Curve deleted."
        }
    }
    /// Read-before-write catches stale drafts; the server owns the atomic curve/claim transaction.
    private static func checkOriginal(_ original: PodCurve?, latest: [PodCurve]) throws {
        if let original, !latest.contains(original) { throw APIError.serverError(message: "This curve changed on another device. Reload and reopen it before saving.") }
    }
    private func change(_ action: (any CurveClient, Int) async throws -> String) async -> Bool {
        guard loaded, !saving else { return false }
        saving = true; revision += 1; let operation = revision; let client = api; error = nil; notice = nil
        defer { if revision == operation { saving = false; loading = false } }
        do {
            let message = try await action(client, operation)
            guard revision == operation else { return false }
            notice = message
            do {
                let snapshot = try await client.library()
                guard revision == operation else { return true }
                curves = snapshot.curves; supportsAssignments = snapshot.supportsAssignments
            } catch { if revision == operation { loaded = false; self.error = "Saved, but the curve library could not be refreshed. Reload before another change." } }
            return true
        } catch { if revision == operation { self.error = error.localizedDescription }; return false }
    }
    func start(_ draft: RunOnceDraft, now: Date = .now, timeZone: TimeZone) async -> Bool {
        if let validation = draft.validation(now: now, timeZone: timeZone) { error = validation; return false }
        guard !saving else { return false }
        saving = true; revision += 1; let operation = revision; let client = api; error = nil
        defer { if revision == operation { saving = false } }
        do {
            _ = try await client.start(side: draft.side, points: draft.points.map { RunOnceSetPoint(time: $0.time, temperature: $0.temperature) }, wake: draft.wake)
            guard revision == operation else { return false }
            notice = "Run-once start accepted."
            do { let session = try await client.active(draft.side); if revision == operation { sessions[draft.side] = session } }
            catch { if revision == operation { self.error = "Start accepted, but its status could not be refreshed. Reload before trying again." } }
            return true
        } catch { if revision == operation { self.error = error.localizedDescription }; return false }
    }
    func cancel(_ side: Side) async {
        guard !saving else { return }
        saving = true; revision += 1; let operation = revision; let client = api; error = nil
        defer { if revision == operation { saving = false } }
        do {
            try await client.cancel(side)
            guard revision == operation else { return }
            sessions.removeValue(forKey: side); notice = "Run once cancelled. The recurring schedule resumes."
        } catch { if revision == operation { self.error = error.localizedDescription } }
    }
}

struct RunOnceDraft: Identifiable, Sendable {
    let id = UUID()
    var side: Side
    var curve: PodCurve
    var points: [CurvePoint]
    var wake: String
    init(curve: PodCurve, side: Side, now: Date = .now, timeZone: TimeZone) {
        self.curve = curve; self.side = side
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let start = CurvePoint.clock(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))
        wake = CurvePoint.clock((AlarmDraft.clockMinutes(start) ?? 0) + 8 * 60)
        points = CurvePoint.rebase(curve.ordered, from: curve.bedtime, until: curve.wake, to: start, until: wake)
    }
    mutating func setWake(_ value: String) {
        points = CurvePoint.rebase(points, from: points.first?.time ?? "22:00", until: wake, to: points.first?.time ?? "22:00", until: value)
        wake = value
    }
    func validation(now: Date, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard let clock = AlarmDraft.clockMinutes(wake), let end = calendar.nextDate(after: now, matching: DateComponents(hour: clock / 60, minute: clock % 60), matchingPolicy: .nextTime, repeatedTimePolicy: .first), end.timeIntervalSince(now) <= 14 * 3600 else {
            return "Choose a wake time within the next 14 hours."
        }
        if points.isEmpty || points.count > 96 || Set(points.map(\.time)).count != points.count { return "Choose a longer window so each set point has its own time." }
        let start = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let total = (clock - start + 1440) % 1440
        if points.dropFirst().contains(where: { ($0.minutes - start + 1440) % 1440 > total }) {
            return "This preview has passed its start time. Close it and review a fresh run-once curve."
        }
        return nil
    }
}
