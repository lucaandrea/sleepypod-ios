import Foundation
import Observation

/// Personal quiet is sent once. Fresh reads and receipt recovery never resend it.
@MainActor @Observable final class PersonalQuietWorkspace {
    let connection: PersonalBedConnection
    private(set) var page: PersonalQuietPage?
    private(set) var pending: PersonalQuietWrite?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var isInvalidated = false
    private(set) var fresh = false
    private var generation = 0
    private var receivedUptime: TimeInterval?
    private let client: any PersonalQuietTransport
    private let permitted: @MainActor () -> Bool
    private let revoked: @MainActor () -> Void
    private let now: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
    init(connection: PersonalBedConnection, client: any PersonalQuietTransport,
         permitted: @escaping @MainActor () -> Bool = { true }, revoked: @escaping @MainActor () -> Void = {},
         now: @escaping @MainActor () -> Date = { .now }, uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.connection = connection; self.client = client; self.permitted = permitted
        self.revoked = revoked; self.now = now; self.uptime = uptime
    }
    var enabled: Bool { !isInvalidated && permitted() && connection.session.capabilities.householdQuiet == true }
    var currentPage: PersonalQuietPage? { enabled && readingIsFresh ? page : nil }
    var editable: Bool { enabled && !busy && pending == nil && currentPage != nil }
    private var milliseconds: Int64 { Int64(now().timeIntervalSince1970 * 1000) }
    private var readingIsFresh: Bool {
        guard let page, let receivedUptime else { return false }
        let elapsed = uptime() - receivedUptime, clock = milliseconds
        return elapsed >= 0 && elapsed < 15 && clock >= page.generatedAt - 5000
            && clock - page.generatedAt < PersonalQuietContract.observationLifetime
            && (page.mine.until.map { $0 > clock } ?? true) && (page.shared.until.map { $0 > clock } ?? true)
    }
    func tick() { fresh = enabled && readingIsFresh }
    func suspend() {
        generation += 1; page = nil; receivedUptime = nil; fresh = false; busy = false; error = nil; notice = nil
    }
    func invalidate() { isInvalidated = true; suspend(); pending = nil }
    func refresh() async {
        guard enabled, !busy else { return }
        let operation = generation; busy = true
        if pending == nil { error = nil }
        defer { finish(operation) }
        do { show(try await reading(operation)) }
        catch { fail(error, operation: operation) }
    }
    // A failed or uncertain operation needs explicit recovery, not a flickering retry loop.
    func poll() async {
        guard page != nil, error == nil, pending == nil else { return }
        await refresh()
    }
    func change(minutes: Int?) async {
        guard editable, let selected = currentPage else { return }
        if let minutes, ![30, 60, 120, 480].contains(minutes) { return }
        let operation = generation; busy = true; error = nil; notice = nil
        defer { finish(operation) }
        do {
            let latest = try await reading(operation)
            guard latest.mine.revision == selected.mine.revision else { throw HouseholdFailure.conflict }
            let issuedAt = milliseconds
            let request = PersonalQuietWrite(requestId: UUID().uuidString.lowercased(),
                expectedSessionRevision: connection.session.sessionRevision, expectedAssignmentRevision: connection.session.assignmentRevision,
                expectedRevision: latest.mine.revision, issuedAt: issuedAt, expiresAt: issuedAt + 30_000,
                until: minutes.map { issuedAt + Int64($0) * 60_000 })
            try request.validate(); pending = request
            let response = try await client.write(request)
            try response.validate(for: await freshSession(operation)); try checkClock(response.generatedAt)
            guard response.receipt != nil else { throw HouseholdFailure.uncertain }
            try await resolve(response.receipt, request: request, operation: operation)
        } catch { fail(error, operation: operation) }
    }
    func reconcile() async {
        guard enabled, !busy, let pending else { return }
        let operation = generation; busy = true; error = nil
        defer { finish(operation) }
        do {
            _ = try await freshSession(operation)
            let response = try await client.receipt(requestId: pending.requestId)
            try response.validate(for: await freshSession(operation)); try checkClock(response.generatedAt)
            try await resolve(response.receipt, request: pending, operation: operation)
        } catch { fail(error, operation: operation) }
    }
    private func resolve(_ receipt: PersonalQuietReceipt?, request: PersonalQuietWrite, operation: Int) async throws {
        if let receipt {
            guard receipt.requestId == request.requestId, receipt.until == request.until,
                  receipt.savedAt >= request.issuedAt - 5000, receipt.savedAt <= request.expiresAt else { throw HouseholdFailure.invalid }
        }
        let result = try await reading(operation); show(result)
        if receipt == nil && result.generatedAt <= request.expiresAt {
            error = "No saved result is available yet. Check again shortly. Nothing was resent."; return
        }
        pending = nil; error = nil
        if let receipt {
            notice = result.mine.revision != receipt.revision
                ? "Your request was saved, then changed again. Showing the current quiet status."
                : request.until == nil ? "Your quiet request ended. Any other person’s request stays in effect." : "Your quiet request is saved on the Pod."
        } else { notice = "The request expired without a saved result. Showing the current quiet status." }
    }
    private func reading(_ operation: Int) async throws -> PersonalQuietPage {
        _ = try await freshSession(operation)
        let result = try await client.read()
        try result.validate(for: await freshSession(operation))
        try checkClock(result.generatedAt)
        return result
    }
    private func checkClock(_ generatedAt: Int64) throws {
        guard milliseconds >= generatedAt - 5000, milliseconds - generatedAt < PersonalQuietContract.observationLifetime else { throw HouseholdFailure.invalid }
    }
    private func freshSession(_ operation: Int) async throws -> HouseholdSession {
        let session = try await client.session()
        guard operation == generation, enabled, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
        try session.validate()
        guard session == connection.session else { throw HouseholdFailure.changedIdentity }
        return session
    }
    private func show(_ result: PersonalQuietPage) { page = result; receivedUptime = uptime(); tick() }
    private func finish(_ operation: Int) { if operation == generation { busy = false } }
    private func fail(_ failure: Error, operation: Int) {
        guard operation == generation else { return }
        page = nil; receivedUptime = nil; fresh = false
        switch failure as? HouseholdFailure {
        case .authentication:
            invalidate(); revoked(); error = "Your personal connection was revoked. Reconnect before changing quiet time."
        case .changedIdentity, .forbidden, .unavailable:
            invalidate(); error = "Your account or access changed. Refresh your personal account to continue."
        case .conflict:
            error = "Your quiet request changed on another device. Refresh before making a new change."
        default:
            error = pending == nil ? "Quiet status could not be verified. Refresh before making a change."
                : "The save result is unknown. Check the saved result before making another change. Nothing will be resent."
        }
    }
}
