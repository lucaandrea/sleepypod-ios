import Foundation
import Observation

/// One private page and selected record remain in memory; lifecycle changes discard every body.
@MainActor @Observable final class PersonalLearningWorkspace {
    let connection: PersonalBedConnection
    private(set) var archives: PersonalLearningArchivePage?
    private(set) var selected: PersonalLearningArchive?
    private(set) var records: PersonalLearningRecordPage?
    private(set) var detail: PersonalLearningDetail?
    private(set) var removal: PersonalLearningRemovalProgress?
    private(set) var busy = false
    private(set) var activity = "Reading saved learning…"
    private(set) var error: String?
    private(set) var isInvalidated = false
    private let client: any PersonalLearningTransport
    private let permitted: @MainActor () -> Bool
    private let revoked: @MainActor () -> Void
    private var generation = 0
    private var checkingAccess = false
    init(connection: PersonalBedConnection, client: any PersonalLearningTransport,
         permitted: @escaping @MainActor () -> Bool = { true }, revoked: @escaping @MainActor () -> Void = {}) {
        self.connection = connection; self.client = client; self.permitted = permitted; self.revoked = revoked
    }
    var enabled: Bool { !isInvalidated && permitted() && connection.session.capabilities.personalLearningArchive == true }
    var removalAvailable: Bool { enabled && connection.session.capabilities.personalLearningRemoval == true }
    func suspend() { generation += 1; archives = nil; selected = nil; records = nil; detail = nil; removal = nil; busy = false; error = nil }
    func invalidate() { isInvalidated = true; suspend() }
    func closeRecord() { generation += 1; detail = nil; removal = nil; busy = false; error = nil }
    func closeArchive() { closeRecord(); selected = nil; records = nil }

    func refresh() async {
        guard enabled, !busy else { return }
        suspend()
        await readArchives(previous: nil)
    }
    func olderArchives() async {
        guard let archives, archives.nextCursor != nil else { return }
        await readArchives(previous: archives)
    }
    private func readArchives(previous: PersonalLearningArchivePage?) async {
        guard enabled, !busy else { return }
        let operation = begin()
        defer { finish(operation) }
        do {
            let session = try await freshSession(operation)
            let page = try await client.archives(before: previous?.nextCursor, limit: 20)
            try check(operation); try page.validate(for: session, before: previous?.nextCursor)
            _ = try await freshSession(operation)
            if let last = previous?.archives.last, let first = page.archives.first {
                guard first.capturedAt < last.capturedAt || (first.capturedAt == last.capturedAt && first.id < last.id) else { throw HouseholdFailure.conflict }
            }
            archives = page; selected = nil; records = nil
        } catch { fail(error, operation: operation) }
    }
    func openArchive(_ identifier: String) async {
        guard let archive = archives?.archives.first(where: { $0.id == identifier }) else { return }
        await readRecords(archive, after: 0)
    }
    func nextRecords() async {
        guard let selected, let next = records?.nextOrdinal else { return }
        await readRecords(selected, after: next)
    }
    private func readRecords(_ archive: PersonalLearningArchive, after: Int) async {
        guard enabled, !busy else { return }
        let operation = begin()
        selected = archive; records = nil
        defer { finish(operation) }
        do {
            let session = try await freshSession(operation)
            let page = try await client.records(archiveId: archive.id, after: after, limit: 20)
            try check(operation); try page.validate(for: session, archive: archive, after: after)
            _ = try await freshSession(operation)
            records = page
        } catch { fail(error, operation: operation) }
    }
    func openRecord(_ identifier: String) async {
        guard enabled, !busy, let selected, let record = records?.records.first(where: { $0.id == identifier }) else { return }
        let operation = begin()
        defer { finish(operation) }
        do {
            let session = try await freshSession(operation)
            let result = try await client.detail(recordId: identifier)
            try check(operation); try result.validate(for: session, archive: selected, record: record)
            _ = try await freshSession(operation)
            detail = result
        } catch { fail(error, operation: operation) }
    }
    func reviewRemoval() {
        guard removalAvailable, !busy, removal == nil, let detail, !detail.redacted,
              let archive = selected, archive.id == detail.archiveId,
              let record = records?.records.first(where: { $0.id == detail.recordId }) else { return }
        let session = connection.session
        removal = .init(request: .init(version: 1, requestId: UUID().uuidString.lowercased(),
            expectedSessionRevision: session.sessionRevision, expectedAssignmentRevision: session.assignmentRevision,
            recordId: detail.recordId, archiveId: archive.id, expectedPayloadHash: detail.payloadHash, confirmRemoveArchivedCopy: true),
            title: PersonalLearningPresentation.title(record), capturedAt: archive.capturedAt, redactedDetail: detail.removingPayload)
        error = nil
    }
    func cancelRemoval() {
        guard !busy, removal?.phase == .review else { return }
        removal = nil; error = nil
    }
    func confirmRemoval() async { await performRemoval(readReceiptOnly: false) }
    func checkRemovalReceipt() async { await performRemoval(readReceiptOnly: true) }

    /// Send only from an explicit review; every uncertain follow-up reads the same receipt.
    private func performRemoval(readReceiptOnly: Bool) async {
        guard removalAvailable, !busy, let pending = removal,
              pending.phase == (readReceiptOnly ? .uncertain : .review) else { return }
        generation += 1
        let operation = generation
        busy = true; error = nil
        activity = readReceiptOnly ? "Checking removal receipt…" : "Removing saved copy…"
        defer { finish(operation) }
        do {
            let session = try await freshSession(operation)
            try pending.request.validate(for: session)
            // The request can reach the Pod even when its reply is lost. Hide the old content now.
            detail = nil; removal?.phase = .uncertain
            let response: PersonalLearningRemovalResponse
            if readReceiptOnly { response = try await client.removalReceipt(requestId: pending.request.requestId) }
            else { response = try await client.remove(pending.request) }
            try check(operation)
            try response.validate(for: session, request: pending.request, capturedAt: pending.capturedAt)
            _ = try await freshSession(operation)
            guard let receipt = response.receipt else {
                error = "The Pod has not confirmed this removal. Check the saved result again; the app will not resend the removal."
                return
            }
            removal?.phase = .removed; removal?.receipt = receipt
            detail = pending.redactedDetail
            records = records?.removingPayload(pending.request.recordId)
        } catch {
            guard operation == generation else { return }
            if removal?.phase == .uncertain,
               ![HouseholdFailure.authentication, .changedIdentity, .forbidden, .unavailable].contains(error as? HouseholdFailure ?? .uncertain) {
                detail = nil
                self.error = "Removal is not confirmed. The saved content is hidden until the Pod verifies the result. Check the removal receipt when connected."
            } else { fail(error, operation: operation) }
        }
    }
    func checkAccess() async {
        guard !isInvalidated else { return }
        guard enabled else { invalidate(); return }
        guard !busy, !checkingAccess, archives != nil else { return }
        let operation = generation
        checkingAccess = true
        defer { checkingAccess = false }
        do { _ = try await freshSession(operation) }
        catch { if !Task.isCancelled { fail(error, operation: operation) } }
    }
    private func freshSession(_ operation: Int) async throws -> HouseholdSession {
        let session = try await client.session()
        try check(operation); try session.validate()
        guard session == connection.session else { throw HouseholdFailure.changedIdentity }
        guard session.capabilities.personalLearningArchive == true else { throw HouseholdFailure.unavailable }
        return session
    }
    private func check(_ operation: Int) throws {
        guard operation == generation, enabled, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
    private func begin() -> Int {
        generation += 1; busy = true; detail = nil; removal = nil; error = nil
        activity = "Reading saved learning…"
        return generation
    }
    private func finish(_ operation: Int) { if operation == generation { busy = false } }
    private func fail(_ failure: Error, operation: Int) {
        guard operation == generation else { return }
        suspend()
        switch failure as? HouseholdFailure {
        case .authentication:
            isInvalidated = true; revoked()
            error = "Your personal connection is unavailable or revoked. Reconnect before opening saved learning."
        case .changedIdentity:
            isInvalidated = true
            error = "Your account or assignment changed. Previous saved learning is hidden. Refresh your personal account."
        case .unavailable, .forbidden:
            error = "Saved learning is unavailable on this Pod. Refresh your personal account to check access."
        case .rateLimited:
            error = "Too many library requests. Wait before reloading."
        default:
            error = "Your saved learning could not be verified. Reload the library to try again."
        }
    }
}
