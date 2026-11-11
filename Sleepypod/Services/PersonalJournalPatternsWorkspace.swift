import Foundation
import Observation

/// A separate read generation lets a comparison fail without losing the open unsaved check-in.
@MainActor @Observable final class PersonalJournalPatternsWorkspace {
    private(set) var result: PersonalJournalPatterns?
    private(set) var busy = false
    private(set) var error: String?
    private let connection: PersonalBedConnection
    private let client: any PersonalJournalTransport
    private let permitted: @MainActor () -> Bool
    private let invalidated: @MainActor (HouseholdFailure) -> Void
    private var generation = 0
    init(connection: PersonalBedConnection, client: any PersonalJournalTransport,
         permitted: @escaping @MainActor () -> Bool, invalidated: @escaping @MainActor (HouseholdFailure) -> Void) {
        self.connection = connection; self.client = client; self.permitted = permitted; self.invalidated = invalidated
    }
    var available: Bool { connection.session.capabilities.personalJournalPatterns == true }
    var enabled: Bool { available && permitted() }
    func clear() { generation += 1; result = nil; busy = false; error = nil }
    func load(_ range: PersonalJournalRange) async {
        guard enabled, !busy else { return }
        clear(); let operation = generation; busy = true
        defer { if operation == generation { busy = false } }
        do {
            try range.validate()
            _ = try await freshSession(operation)
            let response = try await client.patterns(range: range)
            try check(operation)
            try response.validate(for: await freshSession(operation), range: range)
            result = response
        } catch {
            guard operation == generation, !Task.isCancelled else { return }
            switch error as? HouseholdFailure {
            case .authentication, .changedIdentity:
                clear(); invalidated(error as? HouseholdFailure ?? .changedIdentity)
            case .forbidden, .unavailable:
                self.error = "Personal comparisons are unavailable on this Pod. Your check-in is still available."
            default:
                self.error = "The comparison could not be verified. Choose up to 90 dates and try again. Your unsaved check-in is unchanged."
            }
        }
    }
    private func freshSession(_ operation: Int) async throws -> HouseholdSession {
        let session = try await client.session()
        try check(operation); try session.validate()
        guard session == connection.session else { throw HouseholdFailure.changedIdentity }
        guard session.capabilities.personalJournalPatterns == true else { throw HouseholdFailure.unavailable }
        return session
    }
    private func check(_ operation: Int) throws {
        guard operation == generation, enabled, !Task.isCancelled else { throw HouseholdFailure.changedIdentity }
    }
}
