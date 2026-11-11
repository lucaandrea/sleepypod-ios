import Foundation
import Observation

struct PersonalJournalDraft: Equatable {
    var restfulness: Int?
    var comfort: String?
    var notes: String
    var context: MorningJournalContextDraft
    init(fields: MorningJournalFields?, timeZone: String) {
        restfulness = fields?.restfulness; comfort = fields?.comfort; notes = fields?.notes ?? ""
        context = .init(fields: fields ?? .init(), timeZone: timeZone)
    }
    func fields(date: String, timeZone: String, now: Date) throws -> MorningJournalFields {
        guard let restfulness, let comfort else {
            throw MorningJournalFailure.unavailable("Choose how rested and comfortable you felt.")
        }
        var fields = MorningJournalFields()
        fields.restfulness = restfulness; fields.comfort = comfort; fields.notes = notes
        fields = try context.fields(from: fields, date: date, timeZone: timeZone, now: now)
        try fields.validate()
        return fields.normalized
    }
}

/// Only the open account's draft is retained. Receipt recovery reads current state and never resends a write.
@MainActor @Observable final class PersonalJournalWorkspace {
    struct Pending: Equatable {
        let requestId: String
        let date: String
        let timeZone: String
        let outcome: String
    }
    let connection: PersonalBedConnection
    private(set) var page: PersonalJournalPage?
    private(set) var draft: PersonalJournalDraft?
    private(set) var dirty = false
    private(set) var pending: Pending?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var isInvalidated = false
    private let client: any PersonalJournalTransport
    private let permitted: @MainActor () -> Bool
    private let revoked: @MainActor () -> Void
    private let now: @MainActor () -> Date
    private var generation = 0
    private var checkingAccess = false
    init(connection: PersonalBedConnection, client: any PersonalJournalTransport,
         permitted: @escaping @MainActor () -> Bool = { true }, revoked: @escaping @MainActor () -> Void = {},
         now: @escaping @MainActor () -> Date = { .now }) {
        self.connection = connection; self.client = client; self.permitted = permitted; self.revoked = revoked; self.now = now
    }
    var enabled: Bool { !isInvalidated && permitted() && connection.session.capabilities.personalJournal == true }
    var selected: PersonalJournalSelection? { page?.entries.first }
    var timeZone: String { selected?.timeZone ?? page?.currentTimeZone ?? "GMT" }
    var hasUnsaved: Bool { dirty || pending != nil }
    var editable: Bool { enabled && !busy && pending == nil && page != nil }
    var canSave: Bool { editable && dirty && (try? validatedFields()) != nil }
    var validationIssue: String? {
        guard dirty, draft?.restfulness != nil, draft?.comfort != nil else { return nil }
        do { _ = try validatedFields(); return nil }
        catch { return error.localizedDescription }
    }
    var entryStatus: String {
        if pending != nil { return "Last loaded entry — save result not yet confirmed" }
        if dirty { return "Unsaved changes to your check-in" }
        return selected?.record == nil ? "No saved check-in for this morning" : "Your saved check-in"
    }
    func suspend() { generation += 1; page = nil; draft = nil; dirty = false; pending = nil; busy = false; error = nil; notice = nil }
    func invalidate() { isInvalidated = true; suspend() }
    func edit(_ value: PersonalJournalDraft) {
        guard editable, draft != nil else { return }
        draft = value; dirty = true; error = nil; notice = nil
    }
    private func validatedFields() throws -> MorningJournalFields {
        guard let draft, let selected else { throw HouseholdFailure.invalid }
        return try draft.fields(date: selected.date, timeZone: timeZone, now: now())
    }
    func open(date: String? = nil, discardDraft: Bool = false) async {
        guard enabled, !busy else { return }
        guard !hasUnsaved || discardDraft else { error = "Review your unsaved check-in before opening another entry."; return }
        suspend(); let operation = generation; busy = true
        defer { finish(operation) }
        do {
            var result = try await read(date: date ?? MorningJournalDates.key(now(), timeZone: "GMT"), operation: operation)
            if date == nil, result.query.date != result.today { result = try await read(date: result.today, operation: operation) }
            show(result)
        } catch { fail(error, operation: operation) }
    }
    func save(remove: Bool = false) async {
        guard editable, let selected, !remove || selected.record != nil else { return }
        let fields: MorningJournalFields?
        do { fields = remove ? nil : try validatedFields() }
        catch { self.error = error.localizedDescription; return }
        generation += 1; let operation = generation; busy = true; error = nil; notice = nil
        defer { finish(operation) }
        do {
            let session = try await freshSession(operation)
            try page?.scope.validate(for: session)
            let request = PersonalJournalWrite(requestId: UUID().uuidString.lowercased(), expectedSessionRevision: session.sessionRevision,
                expectedAssignmentRevision: session.assignmentRevision, date: selected.date, expectedRevision: selected.revision,
                expectedTimeZone: timeZone, fields: fields)
            let waiting = Pending(requestId: request.requestId, date: selected.date, timeZone: timeZone, outcome: remove ? "deleted" : "saved")
            pending = waiting
            let result = try await client.write(request)
            try check(operation)
            let after = try await freshSession(operation)
            try result.validate(for: after)
            guard let receipt = try matching(result.receipt, waiting) else { throw HouseholdFailure.uncertain }
            try await showSaved(receipt, operation: operation)
        } catch { fail(error, operation: operation) }
    }
    func reconcile() async {
        guard enabled, !busy, let pending else { return }
        generation += 1; let operation = generation; busy = true; error = nil; notice = nil
        defer { finish(operation) }
        do {
            _ = try await freshSession(operation)
            let result = try await client.receipt(requestId: pending.requestId)
            try check(operation)
            try result.validate(for: await freshSession(operation))
            if let receipt = try matching(result.receipt, pending) { try await showSaved(receipt, operation: operation) }
            else { error = "No saved result is available yet. Nothing was resent. Check again, or reopen the current entry before deciding what to do." }
        } catch { fail(error, operation: operation) }
    }
    func checkAccess() async {
        guard !isInvalidated else { return }
        guard enabled else { invalidate(); return }
        guard !busy, !checkingAccess, page != nil else { return }
        let operation = generation; checkingAccess = true
        defer { checkingAccess = false }
        do { _ = try await freshSession(operation) }
        catch {
            guard operation == generation, !Task.isCancelled else { return }
            fail(error, operation: operation)
            if !isInvalidated { suspend(); self.error = "Your account access could not be verified. Reopen the saved check-in to continue." }
        }
    }
    private func read(date: String, operation: Int) async throws -> PersonalJournalPage {
        guard MorningJournalDates.valid(date) else { throw HouseholdFailure.invalid }
        _ = try await freshSession(operation)
        let result = try await client.read(date: date)
        try check(operation)
        try result.validate(for: await freshSession(operation), date: date)
        return result
    }
    private func show(_ result: PersonalJournalPage, notice: String? = nil) {
        page = result
        draft = .init(fields: result.entries[0].record?.fields, timeZone: result.entries[0].timeZone ?? result.currentTimeZone)
        dirty = false; pending = nil; error = nil; self.notice = notice
    }
    private func matching(_ receipt: PersonalJournalReceipt?, _ pending: Pending) throws -> PersonalJournalReceipt? {
        if let receipt {
            guard receipt.requestId == pending.requestId, receipt.date == pending.date, receipt.timeZone == pending.timeZone,
                  receipt.outcome == pending.outcome else { throw HouseholdFailure.invalid }
        }
        return receipt
    }
    private func showSaved(_ receipt: PersonalJournalReceipt, operation: Int) async throws {
        let result = try await read(date: receipt.date, operation: operation)
        let message = result.entries[0].revision != receipt.revision
            ? "Your change was saved, then this entry changed again. Showing the current saved entry."
            : receipt.outcome == "saved" ? "Check-in saved privately on your Pod." : "Check-in removed. Existing backups and exports are unchanged."
        show(result, notice: message)
    }
    private func freshSession(_ operation: Int) async throws -> HouseholdSession {
        let session = try await client.session()
        try check(operation); try session.validate()
        guard session == connection.session else { throw HouseholdFailure.changedIdentity }
        guard session.capabilities.personalJournal == true else { throw HouseholdFailure.unavailable }
        return session
    }
    private func check(_ operation: Int) throws {
        guard operation == generation, enabled, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
    private func finish(_ operation: Int) { if operation == generation { busy = false } }
    private func fail(_ failure: Error, operation: Int) {
        guard operation == generation else { return }
        switch failure as? HouseholdFailure {
        case .authentication:
            invalidate(); revoked(); error = "Your personal connection was revoked. Reconnect before opening check-ins."
        case .changedIdentity:
            invalidate(); error = "Your account or assignment changed. Previous check-in content is hidden. Refresh your personal account."
        case .forbidden, .unavailable:
            suspend(); error = "Personal check-ins are unavailable on this Pod. Refresh your personal account to check access."
        default:
            error = pending == nil ? "The check-in could not be verified. Open the saved entry again to continue."
                : "The save result is not confirmed. Check its result before making another change."
        }
    }
}
