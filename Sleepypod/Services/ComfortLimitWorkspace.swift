import Foundation
import FreeSleepKit
import Observation

@MainActor @Observable final class ComfortLimitWorkspace {
    private var value: ComfortLimitPage?
    private var owner: [String]?
    private var side: Side = .left
    private var client: (any ComfortLimitClient)?
    private var generation = 0
    private let currentOwner: () -> [String]?
    private(set) var busy = false
    private(set) var error: String?
    var page: ComfortLimitPage? { owner != nil && owner == currentOwner() ? value : nil }

    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }) {
        self.currentOwner = currentOwner
    }
    func configure(side: Side, client: (any ComfortLimitClient)?) {
        invalidate(); self.side = side; self.client = client; owner = currentOwner()
    }
    func invalidate() { generation += 1; value = nil; owner = nil; busy = false; error = nil }

    func refresh() async {
        guard !busy, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        guard let client else { error = "Connect to an updated Sleepypod Core to view and change the comfort limit."; return }
        busy = true; let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            let received = try await client.read(side: side)
            try received.validate(for: side)
            guard current(operation, owner) else { return }
            value = received; error = nil
        } catch {
            guard current(operation, owner) else { return }
            value = nil; self.error = "The comfort limit could not be checked. Reconnect or update the Pod, then refresh."
        }
    }

    /// One request only. Never retry or retain a pending configuration after an account or connection change.
    func save(_ configuration: ComfortLimitConfiguration, original: ComfortLimitPage) async -> Bool {
        guard !busy, let owner, owner == currentOwner(), let client, configuration.isValid,
              let currentPage = page, currentPage == original, !Task.isCancelled else { return false }
        busy = true; let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            let received = try await client.save(.init(side: side, expectedSourceSide: original.sourceSide,
                expectedRevision: original.revision, config: configuration))
            try received.validate(for: side)
            guard current(operation, owner) else { return false }
            guard received.revision == original.revision + 1, received.config == configuration,
                  received.sourceSide == original.sourceSide else { throw ComfortLimitError.invalidResponse }
            value = received; error = nil
            return true
        } catch {
            guard current(operation, owner) else { return false }
            value = nil
            self.error = "The save was not confirmed. Refresh to see the current limit before trying again. No retry was queued."
            return false
        }
    }
    private func current(_ operation: Int, _ expectedOwner: [String]) -> Bool {
        generation == operation && owner == expectedOwner && currentOwner() == expectedOwner && !Task.isCancelled
    }
}
