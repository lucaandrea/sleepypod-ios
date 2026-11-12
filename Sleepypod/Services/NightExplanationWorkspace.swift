import Foundation
import FreeSleepKit
import Observation

@MainActor @Observable final class NightExplanationWorkspace {
    private var value: NightExplanation?
    private(set) var loading = false
    private(set) var error: String?
    private var client: (any NightExplanationClient)?
    private var owner: [String]?
    private var side: Side = .left
    private var wakeDate = ""
    private var generation = 0
    private let currentOwner: () -> [String]?
    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }) {
        self.currentOwner = currentOwner
    }
    func report(at now: Date) -> NightExplanation? {
        guard owner != nil, owner == currentOwner(), let value, value.current(at: now) else { return nil }
        return value
    }
    func configure(client: (any NightExplanationClient)?, side: Side, wakeDate: String) {
        invalidate(); self.client = client; self.side = side; self.wakeDate = wakeDate; owner = currentOwner()
    }
    func invalidate() { generation += 1; value = nil; loading = false; error = nil; owner = nil }
    /// Each read belongs to one connection, zone and morning; late replies cannot replace a newer selection.
    func refresh() async {
        guard !loading, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        guard let client else { error = "Connect to an updated Sleepypod Core controller to read night history."; return }
        loading = true; let operation = generation, expectedSide = side, expectedDate = wakeDate
        defer { if operation == generation { loading = false } }
        do {
            let report = try await client.read(side: expectedSide, wakeDate: expectedDate)
            try report.validate()
            guard report.side == expectedSide, report.wakeDate == expectedDate else { throw APIError.invalidResponse(statusCode: 0) }
            guard current(operation, owner) else { return }
            value = report; error = nil
        } catch {
            guard current(operation, owner) else { return }
            value = nil; self.error = "Night evidence is unavailable. Choose a started night within the last 30 days, then check your connection and Pod time zone."
        }
    }
    private func current(_ operation: Int, _ expectedOwner: [String]) -> Bool {
        generation == operation && owner == expectedOwner && currentOwner() == expectedOwner && !Task.isCancelled
    }
}
