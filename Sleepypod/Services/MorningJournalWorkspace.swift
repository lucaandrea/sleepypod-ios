import Foundation
import Observation

@MainActor @Observable final class MorningJournalWorkspace {
    struct Draft {
        var original: MorningJournalSelection
        var fields: MorningJournalFields
        var comparison: MorningJournalSelection?
        var needsReadback = false
        var pending: MorningJournalWrite?
        var pendingDraft: MorningJournalFields?
        var dirty: Bool { fields.normalized != (original.record?.fields ?? MorningJournalFields()) }
    }
    private(set) var client: (any MorningJournalClient)?
    private(set) var page: MorningJournalPage?
    private(set) var side: Side = .left
    private(set) var date: String?
    private(set) var days = 30
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var drafts: [String: Draft] = [:]
    private var generation = 0
    private var owner: [String] = []
    private var available = false
    private var key: String? { date.map { "\(side.rawValue)|\($0)" } }
    var draft: Draft? { key.flatMap { drafts[$0] } }
    var hasUnsaved: Bool { drafts.values.contains { $0.dirty || $0.needsReadback || $0.comparison != nil } }
    var canSave: Bool { !busy && page != nil && available && draft.map { !$0.needsReadback && $0.comparison == nil } == true }

    func configure(client: (any MorningJournalClient)?, side: Side) {
        invalidate(); self.client = client; self.side = side; owner = OwnerConnection.revision
        date = nil; available = false; drafts = [:]; notice = nil
        error = client == nil ? "Connect to your controller to read morning check-ins." : nil
    }
    func invalidate() { generation += 1; busy = false; page = nil }
    func edit(_ value: MorningJournalFields) {
        guard !busy, let key, drafts[key] != nil else { return }
        drafts[key]?.fields = value; notice = nil
    }
    func load(side: Side? = nil, date: String? = nil, days: Int? = nil) async {
        guard !busy, let client, owner == OwnerConnection.revision else { return }
        generation += 1; let operation = generation
        let selectedSide = side ?? self.side, selectedDate = date ?? self.date, selectedDays = days ?? self.days
        self.side = selectedSide; self.date = selectedDate; self.days = selectedDays
        busy = true; page = nil; error = nil; notice = nil
        defer { if generation == operation { busy = false } }
        do {
            if !available { try await client.available() }
            guard current(operation) else { return }
            let result = try await client.read(side: selectedSide, date: selectedDate, days: selectedDays)
            try result.validate(side: selectedSide, date: selectedDate, days: selectedDays)
            guard current(operation) else { return }
            available = true; page = result; self.date = result.through
            reconcile(result.selected)
        } catch { if current(operation) { self.error = APIError.message(for: error) } }
    }
    /// An explicit read never replaces a dirty draft; compare saved values before another mutation.
    private func reconcile(_ saved: MorningJournalSelection) {
        let entryKey = "\(saved.side.rawValue)|\(saved.date)"
        guard var current = drafts[entryKey] else {
            drafts[entryKey] = .init(original: saved, fields: saved.record?.fields ?? .init()); return
        }
        if let pending = current.pending, saved.revision != pending.expectedRevision,
           saved.record?.fields == pending.fields?.normalized {
            let editedAfterDispatch = current.pendingDraft.map { current.fields.normalized != $0.normalized } ?? false
            current.original = saved
            if !editedAfterDispatch { current.fields = saved.record?.fields ?? .init() }
            current.pending = nil; current.pendingDraft = nil; current.comparison = nil; current.needsReadback = false
            notice = editedAfterDispatch ? "The earlier change is saved. Your newer draft is kept for review; nothing was sent again."
                : "The saved entry matches the requested change. Nothing was sent again."
        } else if saved != current.original || current.needsReadback {
            current.comparison = saved; current.needsReadback = false
            notice = "Review the saved entry and choose which values to keep."
        } else if !current.dirty { current.original = saved; current.fields = saved.record?.fields ?? .init() }
        drafts[entryKey] = current
    }
    func resolve(keepDraft: Bool) {
        guard !busy, let key, var value = drafts[key], let saved = value.comparison else { return }
        value.original = saved; value.comparison = nil; value.pending = nil; value.pendingDraft = nil; value.needsReadback = false
        if !keepDraft { value.fields = saved.record?.fields ?? .init() }
        drafts[key] = value; error = nil
        notice = keepDraft ? "Your draft is kept. Review it, then save to replace the entry you just read." : "Saved entry loaded."
    }
    func resetDraft() {
        guard !busy, let key, let value = drafts[key], value.comparison == nil, !value.needsReadback else { return }
        drafts[key]?.fields = value.original.record?.fields ?? .init(); error = nil; notice = "Draft reset."
    }
    /// The server atomically checks this exact revision, including tombstones after a delete.
    func save(delete: Bool = false) async -> Bool {
        guard canSave, let client, let key, let value = drafts[key], owner == OwnerConnection.revision, !Task.isCancelled else { return false }
        do { if !delete { try value.fields.validate() } } catch { self.error = error.localizedDescription; return false }
        let input = MorningJournalWrite(side: side, date: value.original.date, expectedRevision: value.original.revision, fields: delete ? nil : value.fields.normalized)
        generation += 1; let operation = generation
        busy = true; error = nil; notice = nil; drafts[key]?.pending = input; drafts[key]?.pendingDraft = value.fields; drafts[key]?.needsReadback = true
        defer { if generation == operation { busy = false } }
        do {
            let saved = try await client.write(input); try saved.validate(side: side, date: value.original.date)
            guard current(operation) else { return false }
            guard saved.record?.fields == input.fields, saved.revision != nil, saved.revision != input.expectedRevision else { throw MorningJournalFailure.invalid }
            drafts[key] = .init(original: saved, fields: saved.record?.fields ?? .init())
            // Refresh patterns by reading; a failed refresh must never repeat a successful save.
            notice = delete ? "Check-in deleted." : "Check-in saved."
            do {
                let result = try await client.read(side: side, date: saved.date, days: days)
                try result.validate(side: side, date: saved.date, days: days)
                guard current(operation) else { return true }
                page = result; reconcile(result.selected)
            } catch { if current(operation) { page = nil; self.error = "The change was saved, but its updated patterns could not be loaded. Reload to continue." } }
            return true
        } catch {
            if current(operation) { self.error = APIError.message(for: error) + " Read the saved entry before retrying." }
            return false
        }
    }
    private func current(_ operation: Int) -> Bool { generation == operation && owner == OwnerConnection.revision && !Task.isCancelled }
}
