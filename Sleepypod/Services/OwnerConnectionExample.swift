#if DEBUG
import Foundation
import Observation

/// Exercises the production form and enrollment state machine without saving a key or opening a network connection.
@MainActor @Observable final class OwnerConnectionExample {
    private(set) var waiting = false
    private var reply: CheckedContinuation<Void, Error>?
    private let scenario: String

    init(scenario: String) { self.scenario = scenario }

    static func configured() -> OwnerConnectionExample? {
        guard APIBackend.current.isDemo, let scenario = UserDefaults.standard.string(forKey: "uiConnectionExample") else { return nil }
        return OwnerConnectionExample(scenario: scenario)
    }

    func check(_ candidate: OwnerConnectionCandidate) async throws {
        guard APIBackend.current.isDemo else { throw CancellationError() }
        switch scenario {
        case "authentication": throw APIError.invalidResponse(statusCode: 401)
        case "network": throw URLError(.cannotConnectToHost)
        case "invalid": throw APIError.decodingFailed(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Synthetic non-controller reply")))
        case "pending":
            waiting = true
            defer { waiting = false }
            try await withCheckedThrowingContinuation { reply = $0 }
        default: break
        }
    }

    func complete() { let pending = reply; reply = nil; pending?.resume() }
    func cancel() { let pending = reply; reply = nil; pending?.resume(throwing: CancellationError()) }
}
#endif
