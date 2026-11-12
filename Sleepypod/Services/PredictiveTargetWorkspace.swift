import Foundation
import Observation
import FreeSleepKit

/// Late reads cannot repopulate a different connection, side or personal account.
@MainActor @Observable final class PredictiveTargetWorkspace {
    private var client: (any PredictiveTargetClient)?
    private var owner: [String]?
    private var side: Side = .left
    private var generation = 0
    private var saved: PredictiveTargetPreview?
    private let currentOwner: () -> [String]?
    private let now: () -> Date
    private(set) var busy = false
    private(set) var requested = false
    private(set) var error: String?

    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }, now: @escaping () -> Date = Date.init) {
        self.currentOwner = currentOwner; self.now = now
    }
    func configure(client: (any PredictiveTargetClient)?, side: Side) {
        invalidate(); self.client = client; self.side = side; owner = currentOwner()
    }
    func invalidate() {
        generation += 1; client = nil; owner = nil; saved = nil; busy = false; requested = false; error = nil
    }
    func preview(at date: Date) -> PredictiveTargetPreview? {
        guard !busy, error == nil, let owner, owner == currentOwner(), let saved,
              (try? saved.validate(side: side, now: date)) != nil else { return nil }
        return saved
    }
    func refresh() async {
        guard !busy, !Task.isCancelled, let owner, owner == currentOwner() else { return }
        requested = true; saved = nil; error = nil
        guard let client else { error = "Connect to updated Sleepypod Core to compare targets."; return }
        let token = generation, expectedSide = side
        busy = true
        defer { if generation == token { busy = false } }
        do {
            let result = try await client.preview(side: expectedSide)
            guard current(token, owner) else { return }
            try result.validate(side: expectedSide, now: now())
            saved = result
        } catch {
            guard current(token, owner) else { return }
            self.error = "The comparison could not be read or verified. Check your connection and update Core if needed, then refresh. Previous choices are hidden."
        }
    }
    private func current(_ token: Int, _ expected: [String]) -> Bool {
        generation == token && owner == expected && owner == currentOwner() && !Task.isCancelled
    }
}
