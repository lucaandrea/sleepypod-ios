import Foundation
import Observation

@MainActor @Observable final class NextAlarmWorkspace {
    struct Draft { let base: NextAlarmState; var time: String }
    struct LaterDraft { let base: NextAlarmState; var time: String; var packet: LaterWakePacket? }
    private(set) var current: NextAlarmState?
    private(set) var receivedAt: Date?
    private(set) var draft: Draft?
    private(set) var laterDraft: LaterDraft?
    private(set) var busy = false
    private(set) var requiresReload = false
    private(set) var error: String?
    private(set) var notice: String?
    private var client: (any NextAlarmClient)?
    private var side: Side = .left
    private var owner: [String] = []
    private var generation = 0
    private var capability = false
    private let now: () -> Date
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    var isFresh: Bool {
        guard owner == OwnerConnection.revision, let receivedAt else { return false }
        let age = now().timeIntervalSince(receivedAt)
        return (-5...90).contains(age)
    }
    var canChange: Bool { isFresh && !busy && !requiresReload && current?.canChange == true }
    var changedDraft: Bool { draft.map { $0.base.revision != current?.revision } ?? false }
    var canSaveDraft: Bool { canChange && !changedDraft && draft.map { NextAlarmState.validClock($0.time) } == true }
    var canBeginLater: Bool {
        canChange && draft == nil && laterDraft == nil && current?.state == "scheduled"
            && current?.warming.flatMap { NextAlarmState.instant($0.startsAt) }.map { $0 > now() } == true
    }
    var laterChanged: Bool {
        guard isFresh, !requiresReload, let current, let laterDraft else { return false }
        return current.revision != laterDraft.base.revision || current.alarm?.at != laterDraft.base.alarm?.at
    }
    var canPreviewLater: Bool { canChange && !laterChanged && laterDraft.map { NextAlarmState.validClock($0.time) } == true }
    var laterExpired: Bool {
        guard let packet = laterDraft?.packet else { return false }
        return (try? packet.preview.validate(input: packet.input, now: now())) == nil
    }
    var canApplyLater: Bool { canPreviewLater && laterDraft?.packet != nil && !laterExpired }
    func configure(client: (any NextAlarmClient)?, side: Side) {
        invalidate(); self.client = client; self.side = side; owner = OwnerConnection.revision
        draft = nil; laterDraft = nil; capability = false; requiresReload = false; error = nil; notice = nil
    }
    func invalidate() {
        generation += 1
        if busy { requiresReload = true }
        busy = false; current = nil; receivedAt = nil; laterDraft?.packet = nil
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
            capability = true; current = value; receivedAt = now(); requiresReload = false
            if userInitiated { notice = "Saved alarm loaded. Review it before making another change." }
        } catch { if isCurrent(operation) { current = nil; receivedAt = nil; self.error = APIError.message(for: error) } }
    }
    func beginTime() { guard canChange, laterDraft == nil, let current, let alarm = current.alarm else { return }; draft = .init(base: current, time: alarm.time); notice = nil }
    func editTime(_ value: String) { guard !busy, draft != nil else { return }; draft?.time = value }
    func cancelTime() { guard !busy else { return }; draft = nil }
    func saveTime() async -> Bool { guard canSaveDraft, let draft else { return false }; return await send(base: draft.base, action: "time", time: draft.time) }
    func skip() async -> Bool { guard canChange, laterDraft == nil, let current else { return false }; return await send(base: current, action: "skip") }
    func restore() async -> Bool {
        guard isFresh, !busy, !requiresReload, laterDraft == nil, let current, current.change != nil else { return false }
        return await send(base: current, action: "restore")
    }
    func beginLater() {
        guard canBeginLater, let current, let alarm = current.alarm else { return }
        laterDraft = .init(base: current, time: alarm.time); notice = nil; error = nil
    }
    func editLaterTime(_ time: String) {
        guard !busy, laterDraft != nil else { return }
        laterDraft?.time = time; laterDraft?.packet = nil; error = nil
    }
    func closeLater() { guard !busy else { return }; laterDraft = nil }

    /// Preview is read-only; every returned interval is validated before it is shown.
    func previewLater() async {
        guard canPreviewLater, let laterDraft, !Task.isCancelled else { return }
        guard let client = client as? any LaterWakeClient else {
            error = "Connect to an updated controller to review a later wake. Practice never changes an alarm."
            return
        }
        generation += 1; let operation = generation; busy = true; error = nil; notice = nil
        self.laterDraft?.packet = nil
        defer { if generation == operation { busy = false } }
        do {
            let input = try LaterWakeRequest(base: laterDraft.base, time: laterDraft.time)
            try await client.laterAvailable()
            guard isCurrent(operation), isFresh else { return }
            let packet = try await client.previewLater(input)
            guard isCurrent(operation), isFresh else { return }
            try packet.preview.validate(input: input, now: now())
            self.laterDraft?.packet = packet
        } catch { if isCurrent(operation) { self.error = APIError.message(for: error) } }
    }

    /// A lost or inconsistent save response blocks retries until an explicit saved-state read.
    func applyLater() async -> NextAlarmState? {
        guard canApplyLater, let packet = laterDraft?.packet, let client = client as? any LaterWakeClient,
              !Task.isCancelled else { return nil }
        generation += 1; let operation = generation; busy = true; requiresReload = true; error = nil; notice = nil
        defer { if generation == operation { busy = false } }
        do {
            _ = try packet.application(now: now())
            let result = try await client.applyLater(packet)
            guard isCurrent(operation) else { return nil }
            try packet.preview.validateSaved(result)
            current = result; receivedAt = now(); self.laterDraft = nil; requiresReload = false
            notice = result.schedulerUpdated == true ? "Later wake saved on your controller. Weekly routines are unchanged."
                : "Later wake saved. Timer registration is pending and has not yet been confirmed."
            return result
        } catch {
            if isCurrent(operation) {
                self.laterDraft?.packet = nil
                self.error = "The later wake is not confirmed. Refresh the saved alarm before trying again; it may already have been saved."
            }
            return nil
        }
    }
    /// Send the displayed occurrence once. An uncertain result always needs an explicit read.
    private func send(base: NextAlarmState, action: String, time: String? = nil) async -> Bool {
        guard isFresh, let client, owner == OwnerConnection.revision, !Task.isCancelled else { return false }
        let input: NextAlarmWrite
        do { input = try .init(base: base, action: action, time: time) } catch { self.error = error.localizedDescription; return false }
        generation += 1; let operation = generation; busy = true; requiresReload = true; error = nil; notice = nil
        defer { if generation == operation { busy = false } }
        do {
            let result = try await client.write(input); try result.validate(side: side, write: true)
            guard isCurrent(operation) else { return false }
            guard result.revision != base.revision else { throw NextAlarmFailure.invalid }
            current = result; receivedAt = now(); draft = nil; requiresReload = false
            notice = result.schedulerUpdated == true ? "One-time change saved on your controller."
                : "Change saved. Timer registration is pending and has not yet been confirmed."
            if action == "restore" {
                notice = (notice ?? "") + " Any phone backup is unchanged. Open Phone backup and wake devices to compare it with the restored Pod plan."
            }
            return true
        } catch {
            if isCurrent(operation) { self.error = APIError.message(for: error) + " Refresh the saved alarm before retrying." }
            return false
        }
    }
    private func isCurrent(_ operation: Int) -> Bool { generation == operation && owner == OwnerConnection.revision && !Task.isCancelled }
}
