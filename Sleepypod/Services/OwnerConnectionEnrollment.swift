import Foundation
import Observation

/// A successful status read must still belong to the same form and account before anything is saved.
@MainActor @Observable final class OwnerConnectionEnrollment {
    private(set) var checking = false
    private(set) var message: String?
    private var generation = UUID()

    func invalidate() { generation = UUID(); checking = false; message = nil }

    func connect(_ candidate: OwnerConnectionCandidate,
                 check: (OwnerConnectionCandidate) async throws -> Void,
                 isCurrent: () -> Bool,
                 commit: (OwnerConnectionCandidate) throws -> Void) async -> Bool {
        guard !checking, isCurrent() else { return false }
        invalidate()
        let operation = generation
        checking = true
        defer { if operation == generation { checking = false } }
        do {
            try Task.checkCancellation()
            try await check(candidate)
            try Task.checkCancellation()
            guard operation == generation, isCurrent() else { return false }
            do { try commit(candidate) }
            catch {
                message = "The controller replied, but the connection could not be saved on this device. Your previous connection remains active."
                return false
            }
            message = "Connection verified and saved."
            return true
        } catch {
            guard operation == generation, isCurrent(), !Task.isCancelled else { return false }
            message = Self.failureMessage(error)
            return false
        }
    }

    static func failureMessage(_ error: Error) -> String {
        let detail: String
        switch ConnectionIssue(error) {
        case .authentication:
            if case APIError.invalidResponse(statusCode: 403) = error {
                detail = "This connection does not have access. Check the key or use your personal account."
            } else { detail = "The controller rejected the connection key. Check the key for this address." }
        case .unreachable: detail = "This address could not be reached. Check the address and your network route. A home address needs home-network or private remote access."
        case .timedOut: detail = "The controller did not answer in time. Retry when its network route is available."
        case .invalidResponse: detail = "The address replied, but did not return a usable controller status. Check the selected software and address."
        case .unconfigured: detail = "Enter a complete controller address."
        case .unavailable: detail = "The connection check was interrupted. Check your network and retry."
        }
        return "\(detail) Your saved connection is unchanged."
    }
}
