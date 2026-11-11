import Foundation
import FreeSleepKit
import Observation

@MainActor @Observable final class BedCareWorkspace {
    private var value: BedCare?
    private(set) var loading = false
    private(set) var error: String?
    private var client: (any BedCareClient)?
    private var owner: [String]?
    private var generation = 0
    private let currentOwner: () -> [String]?
    var report: BedCare? { owner != nil && owner == currentOwner() ? value : nil }

    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }) {
        self.currentOwner = currentOwner
    }
    func configure(client: (any BedCareClient)?) { invalidate(); self.client = client; owner = currentOwner() }
    func invalidate() { generation += 1; value = nil; loading = false; error = nil; owner = nil }

    /// Discard responses from a previous connection, cancelled view or failed source.
    func refresh() async {
        guard !loading, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        guard let client else { error = "Connect to an updated Sleepypod Core controller to check bed care."; return }
        loading = true; let operation = generation
        defer { if operation == generation { loading = false } }
        do {
            let report = try await client.read()
            try report.validate()
            guard current(operation, owner) else { return }
            value = report; error = nil
        } catch {
            guard current(operation, owner) else { return }
            value = nil; self.error = "Bed care could not be checked. Reconnect or update your controller, then try again."
        }
    }
    private func current(_ operation: Int, _ expectedOwner: [String]) -> Bool {
        generation == operation && owner == expectedOwner && currentOwner() == expectedOwner && !Task.isCancelled
    }
}
