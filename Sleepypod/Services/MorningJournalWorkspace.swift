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
        var contextDraft: MorningJournalContextDraft?
        var contextTimeZone: String?
        var comparisonTimeZone: String?
        var pendingContextDraft: MorningJournalContextDraft?
        var contextIssue: String?
        var dirty: Bool {
            fields.normalized != (original.record?.fields ?? MorningJournalFields())
                || contextDraft.map { $0 != MorningJournalContextDraft(fields: original.record?.fields ?? .init(), timeZone: contextTimeZone ?? "GMT") } == true
        }
        var timeZoneConflict: Bool { comparisonTimeZone != nil && comparisonTimeZone != contextTimeZone }
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
    var canSave: Bool {
        !busy && page != nil && available && draft.map {
            !$0.needsReadback && $0.comparison == nil && ($0.contextDraft == nil || page?.contextVersion == 1)
        } == true
    }

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
    func editContext(_ value: MorningJournalContextDraft) {
        guard !busy, page?.contextVersion == 1, let key, var draft = drafts[key] else { return }
        draft.contextDraft = value; validateContext(&draft)
        drafts[key] = draft; notice = nil
    }
    private func validateContext(_ draft: inout Draft) {
        do {
            _ = try draft.contextDraft?.fields(from: draft.fields, date: draft.original.date, timeZone: draft.contextTimeZone ?? "GMT")
            draft.contextIssue = nil
        } catch { draft.contextIssue = error.localizedDescription }
    }
    private func newDraft(_ saved: MorningJournalSelection) -> Draft {
        let fields = saved.record?.fields ?? .init()
        let timeZone = saved.record?.timeZone ?? page?.timeZone ?? "GMT"
        var draft = Draft(original: saved, fields: fields)
        if page?.contextVersion == 1 {
            draft.contextDraft = .init(fields: fields, timeZone: timeZone); draft.contextTimeZone = timeZone
            validateContext(&draft)
        }
        return draft
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
            drafts[entryKey] = newDraft(saved); return
        }
        let savedTimeZone = saved.record?.timeZone ?? page?.timeZone ?? "GMT"
        let changedTimeZone = current.contextDraft != nil && current.contextTimeZone != savedTimeZone
        if let pending = current.pending, saved.revision != pending.expectedRevision,
           saved.record?.fields == pending.fields?.normalized,
           pending.expectedTimeZone == nil || saved.record == nil || saved.record?.timeZone == pending.expectedTimeZone {
            let editedAfterDispatch = (current.pendingDraft.map { current.fields.normalized != $0.normalized } ?? false)
                || current.contextDraft != current.pendingContextDraft
            current.original = saved
            if !editedAfterDispatch { current = newDraft(saved) }
            current.pending = nil; current.pendingDraft = nil; current.comparison = nil; current.needsReadback = false
            current.pendingContextDraft = nil; current.comparisonTimeZone = nil
            notice = editedAfterDispatch ? "The earlier change is saved. Your newer draft is kept for review; nothing was sent again."
                : "The saved entry matches the requested change. Nothing was sent again."
        } else if saved != current.original || current.needsReadback || (changedTimeZone && current.dirty) {
            current.comparison = saved; current.needsReadback = false
            current.comparisonTimeZone = savedTimeZone
            notice = "Review the saved entry and choose which values to keep."
        } else if !current.dirty { current = newDraft(saved) }
        drafts[entryKey] = current
    }
    func resolve(keepDraft: Bool) {
        guard !busy, let key, var value = drafts[key], let saved = value.comparison else { return }
        value.original = saved; value.comparison = nil; value.pending = nil; value.pendingDraft = nil; value.needsReadback = false
        if !keepDraft { value = newDraft(saved) }
        else {
            value.contextTimeZone = value.comparisonTimeZone ?? value.contextTimeZone
            value.comparisonTimeZone = nil; value.pendingContextDraft = nil; validateContext(&value)
        }
        drafts[key] = value; error = nil
        notice = keepDraft ? "Your draft is kept. Review it, then save to replace the entry you just read." : "Saved entry loaded."
    }
    func resetDraft() {
        guard !busy, let key, let value = drafts[key], value.comparison == nil, !value.needsReadback else { return }
        drafts[key] = newDraft(value.original); error = nil; notice = "Draft reset."
    }
    /// The server atomically checks this exact revision, including tombstones after a delete.
    func save(delete: Bool = false) async -> Bool {
        guard canSave, let client, let key, let value = drafts[key], owner == OwnerConnection.revision, !Task.isCancelled else { return false }
        let resolved: MorningJournalFields
        do {
            resolved = delete ? value.fields : try value.contextDraft?.fields(from: value.fields, date: value.original.date, timeZone: value.contextTimeZone ?? "GMT") ?? value.fields
            if !delete { try resolved.validate() }
        } catch { self.error = error.localizedDescription; return false }
        let input = MorningJournalWrite(side: side, date: value.original.date, expectedRevision: value.original.revision, fields: delete ? nil : resolved.normalized,
            expectedTimeZone: page?.contextVersion == 1 ? value.contextTimeZone : nil)
        generation += 1; let operation = generation
        busy = true; error = nil; notice = nil; drafts[key]?.pending = input; drafts[key]?.pendingDraft = value.fields; drafts[key]?.needsReadback = true
        drafts[key]?.pendingContextDraft = value.contextDraft
        defer { if generation == operation { busy = false } }
        do {
            let saved = try await client.write(input); try saved.validate(side: side, date: value.original.date)
            guard current(operation) else { return false }
            guard saved.record?.fields == input.fields, saved.revision != nil, saved.revision != input.expectedRevision else { throw MorningJournalFailure.invalid }
            guard input.expectedTimeZone == nil || saved.record == nil || saved.record?.timeZone == input.expectedTimeZone else { throw MorningJournalFailure.invalid }
            drafts[key] = newDraft(saved)
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
