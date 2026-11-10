import Foundation
import FreeSleepKit
import Observation

@MainActor @Observable final class RecordingReadinessWorkspace {
    private var value: RecordingReadiness?
    private(set) var loading = false
    private(set) var error: String?
    private var client: (any RecordingReadinessClient)?
    private var owner: [String]?
    private var generation = 0
    private let currentOwner: () -> [String]?
    var report: RecordingReadiness? { owner != nil && owner == currentOwner() ? value : nil }

    init(currentOwner: @escaping () -> [String]? = {
        PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision
    }) { self.currentOwner = currentOwner }

    func configure(client: (any RecordingReadinessClient)?) {
        invalidate(); self.client = client; owner = currentOwner()
    }
    func invalidate() { generation += 1; value = nil; loading = false; error = nil; owner = nil }

    /// Reads only. Connection changes and cancelled views discard in-flight results.
    func refresh() async {
        guard !loading, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        guard let client else { error = "Connect to an updated Sleepypod Core controller to check recording readiness."; return }
        loading = true; let operation = generation
        defer { if operation == generation { loading = false } }
        do {
            let received = try await client.read()
            try received.validate()
            guard current(operation, owner) else { return }
            value = received; error = nil
        } catch {
            guard current(operation, owner) else { return }
            value = nil
            self.error = "Recording could not be checked. Reconnect or update your controller, then try again."
        }
    }
    private func current(_ operation: Int, _ expectedOwner: [String]) -> Bool {
        generation == operation && owner == expectedOwner && currentOwner() == expectedOwner && !Task.isCancelled
    }
}
