import Foundation
import Observation

@MainActor @Observable final class NextAlarmWorkspace {
    struct Draft { let base: NextAlarmState; var time: String }
    private(set) var current: NextAlarmState?
    private(set) var draft: Draft?
    private(set) var busy = false
    private(set) var requiresReload = false
    private(set) var error: String?
    private(set) var notice: String?
    private var client: (any NextAlarmClient)?
    private var side: Side = .left
    private var owner: [String] = []
    private var generation = 0
    private var capability = false
    var canChange: Bool { !busy && !requiresReload && current?.canChange == true }
    var changedDraft: Bool { draft.map { $0.base.revision != current?.revision } ?? false }
    var canSaveDraft: Bool { canChange && !changedDraft && draft.map { NextAlarmState.validClock($0.time) } == true }
    func configure(client: (any NextAlarmClient)?, side: Side) {
        invalidate(); self.client = client; self.side = side; owner = OwnerConnection.revision
        draft = nil; capability = false; requiresReload = false; error = nil; notice = nil
    }
    func invalidate() {
        generation += 1
        if busy { requiresReload = true }
        busy = false; current = nil
    }
    func load(userInitiated: Bool = false) async {
        guard !busy, !requiresReload || userInitiated, owner == OwnerConnection.revision, !Task.isCancelled else { return }
        guard let client else { error = "Connect to your controller to read the next alarm."; return }
        generation += 1; let operation = generation; busy = true; error = nil
        defer { if generation == operation { busy = false } }
        do {
            if !capability { try await client.available() }
            guard isCurrent(operation) else { return }
            let value = try await client.read(side: side); try value.validate(side: side)
            guard isCurrent(operation) else { return }
            capability = true; current = value; requiresReload = false
            if userInitiated { notice = "Saved alarm loaded. Review it before making another change." }
        } catch { if isCurrent(operation) { current = nil; self.error = APIError.message(for: error) } }
    }
    func beginTime() { guard canChange, let current, let alarm = current.alarm else { return }; draft = .init(base: current, time: alarm.time); notice = nil }
    func editTime(_ value: String) { guard !busy, draft != nil else { return }; draft?.time = value }
    func cancelTime() { guard !busy else { return }; draft = nil }
    func saveTime() async -> Bool { guard canSaveDraft, let draft else { return false }; return await send(base: draft.base, action: "time", time: draft.time) }
    func skip() async -> Bool { guard canChange, let current else { return false }; return await send(base: current, action: "skip") }
    func restore() async -> Bool {
        guard !busy, !requiresReload, let current, current.change != nil else { return false }
        return await send(base: current, action: "restore")
    }
    /// Send the displayed occurrence once. An uncertain result always needs an explicit read.
    private func send(base: NextAlarmState, action: String, time: String? = nil) async -> Bool {
        guard let client, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
        let input: NextAlarmWrite
        do { input = try .init(base: base, action: action, time: time) } catch { self.error = error.localizedDescription; return false }
        generation += 1; let operation = generation; busy = true; requiresReload = true; error = nil; notice = nil
        defer { if generation == operation { busy = false } }
        do {
            let result = try await client.write(input); try result.validate(side: side, write: true)
            guard isCurrent(operation) else { return false }
            guard result.revision != base.revision else { throw NextAlarmFailure.invalid }
            current = result; draft = nil; requiresReload = false
            notice = result.schedulerUpdated == true ? "One-time change saved on your controller."
                : "Change saved. Timer registration is pending and has not yet been confirmed."
            return true
        } catch {
            if isCurrent(operation) { self.error = APIError.message(for: error) + " Refresh the saved alarm before retrying." }
            return false
        }
    }
    private func isCurrent(_ operation: Int) -> Bool { generation == operation && owner == OwnerConnection.revision && !Task.isCancelled }
}
