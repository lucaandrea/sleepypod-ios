import Foundation
import FreeSleepKit
import Observation

/// Read-only inventory. Each result expires independently and is discarded across account or side changes.
@MainActor @Observable final class LearningJourneyWorkspace {
    typealias StageReader = @MainActor (Side) async throws -> PodStageModelResponse
    typealias ThermalReader = @MainActor (Side) async throws -> ThermalModelStatus
    private var stageValue: PodStageModelResponse?
    private var thermalValue: ThermalModelStatus?
    private var stageReadAt: Date?
    private var thermalReadAt: Date?
    private var owner: [String]?
    private var side: Side = .left
    private var generation = 0
    private var readStages: StageReader?
    private var readThermal: ThermalReader?
    private let currentOwner: () -> [String]?
    private(set) var busy = false
    private(set) var stageError: String?
    private(set) var thermalError: String?

    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }) {
        self.currentOwner = currentOwner
    }
    func configure(side: Side, stages: StageReader?, thermal: ThermalReader?) {
        invalidate(); self.side = side; readStages = stages; readThermal = thermal; owner = currentOwner()
    }
    func invalidate() {
        generation += 1; owner = nil; stageValue = nil; thermalValue = nil
        stageReadAt = nil; thermalReadAt = nil; busy = false; stageError = nil; thermalError = nil
    }
    func stages(at now: Date) -> PodStageModelResponse? { isFresh(stageReadAt, now: now) ? stageValue : nil }
    func thermal(at now: Date) -> ThermalModelStatus? { isFresh(thermalReadAt, now: now) ? thermalValue : nil }
    private func isFresh(_ date: Date?, now: Date) -> Bool {
        guard !busy, let owner, owner == currentOwner(), let date else { return false }
        return date <= now.addingTimeInterval(60) && now.timeIntervalSince(date) <= 300
    }

    func refresh() async {
        guard !busy, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        let request = generation, requestedSide = side
        busy = true; stageValue = nil; thermalValue = nil; stageReadAt = nil; thermalReadAt = nil
        stageError = nil; thermalError = nil
        defer { if request == generation { busy = false } }
        do {
            guard let readStages else { throw APIError.noBaseURL }
            let response = try await readStages(requestedSide)
            try response.model?.validate()
            guard current(request, owner) else { return }
            stageValue = response; stageReadAt = .now
        } catch {
            guard current(request, owner) else { return }
            stageError = "Sleep-stage inventory could not be checked. Reconnect, then refresh."
        }
        do {
            guard let readThermal else { throw APIError.noBaseURL }
            let response = try await readThermal(requestedSide)
            try Self.validate(response, side: requestedSide, now: .now)
            guard current(request, owner) else { return }
            thermalValue = response; thermalReadAt = .now
        } catch {
            guard current(request, owner) else { return }
            thermalError = "Temperature evidence could not be checked. Reconnect or update the Pod, then refresh."
        }
    }
    private func current(_ request: Int, _ expectedOwner: [String]) -> Bool {
        request == generation && expectedOwner == owner && owner == currentOwner() && !Task.isCancelled
    }
    static func validate(_ response: ThermalModelStatus, side: Side, now: Date) throws {
        guard response.apiVersion == 1, response.side == side, response.completeNights >= 0,
              response.requiredNights > 0, response.feedbackNights >= 0,
              !response.canTrain || response.completeNights >= response.requiredNights else {
            throw APIError.serverError(message: "The learning response does not match this side or has invalid counts.")
        }
        if let timestamp = response.generatedAt {
            guard timestamp.isFinite else { throw APIError.serverError(message: "The learning response has invalid source timing.") }
            let generated = Date(timeIntervalSince1970: timestamp / 1000)
            guard generated <= now.addingTimeInterval(60), now.timeIntervalSince(generated) <= 300 else {
                throw APIError.serverError(message: "The learning response is no longer current.")
            }
        }
    }
}
