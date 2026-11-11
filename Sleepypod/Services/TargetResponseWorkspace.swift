import Foundation
import Observation
import FreeSleepKit

/// Explicit research operations are fenced by connection identity, physical side and request generation.
@MainActor @Observable final class TargetResponseWorkspace {
    enum Operation { case reading, fitting, previewing }
    private var client: (any TargetResponseClient)?
    private var side: Side = .left
    private var owner: [String]?
    private var generation = 0
    private var savedStatus: TargetResponseResearch?
    private var savedPreview: TargetResponsePreview?
    private let currentOwner: () -> [String]?
    private let now: () -> Date
    private(set) var operation: Operation?
    private(set) var error: String?
    private(set) var notice: String?

    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }, now: @escaping () -> Date = Date.init) {
        self.currentOwner = currentOwner; self.now = now
    }
    func configure(client: (any TargetResponseClient)?, side: Side) {
        invalidate(); self.client = client; self.side = side; owner = currentOwner()
    }
    func invalidate() {
        generation += 1; owner = nil; client = nil; savedStatus = nil; savedPreview = nil
        operation = nil; error = nil; notice = nil
    }
    func status(at date: Date) -> TargetResponseResearch? {
        guard let owner, owner == currentOwner(), let savedStatus, error == nil,
              operation != .reading, operation != .fitting, (try? savedStatus.validate(side: side, now: date)) != nil else { return nil }
        return savedStatus
    }
    func preview(at date: Date) -> TargetResponsePreview? {
        guard operation == nil, status(at: date)?.canPreview == true, let savedPreview,
              (try? savedPreview.validate(side: side, now: date)) != nil else { return nil }
        return savedPreview
    }
    func refresh() async { await perform(.reading) }
    func evaluate() async { await perform(.fitting) }
    func readPreview() async { await perform(.previewing) }

    private func perform(_ requested: Operation) async {
        guard operation == nil, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        guard let client else {
            savedStatus = nil; savedPreview = nil
            error = "Connect to an updated Sleepypod Core controller to inspect response evidence."
            return
        }
        let status = status(at: now())
        guard requested != .fitting || status?.canEvaluate == true,
              requested != .previewing || status?.canPreview == true else { return }
        let token = generation, expectedSide = side
        operation = requested; error = nil; notice = nil; savedPreview = nil
        if requested != .previewing { savedStatus = nil }
        defer { if generation == token { operation = nil } }
        do {
            if requested == .previewing {
                let value = try await client.preview(side: expectedSide)
                guard current(token, owner) else { return }
                try value.validate(side: expectedSide, now: now())
                guard let savedStatus else { throw TargetResponseResearch.invalid }
                try savedStatus.validate(side: expectedSide, now: now())
                guard savedStatus.canPreview else { throw TargetResponseResearch.invalid }
                savedPreview = value
            } else {
                let value: TargetResponseResearch
                if requested == .fitting, let status { value = try await client.evaluate(side: expectedSide, datasetHash: status.datasetHash) }
                else { value = try await client.status(side: expectedSide) }
                guard current(token, owner) else { return }
                try value.validate(side: expectedSide, now: now())
                savedStatus = value
                if requested == .fitting { notice = "Evaluation saved on your Pod. Your bed settings remain unchanged." }
            }
        } catch {
            guard current(token, owner) else { return }
            savedStatus = nil; savedPreview = nil
            self.error = requested == .fitting
                ? "The evaluation reply was not confirmed. Check evidence again to see whether it was saved; this app will not repeat the request automatically."
                : "Response evidence could not be checked. Reconnect or update your Pod, then check again. Previous predictions are hidden."
        }
    }
    private func current(_ token: Int, _ expectedOwner: [String]) -> Bool {
        token == generation && owner == expectedOwner && owner == currentOwner() && !Task.isCancelled
    }
}
