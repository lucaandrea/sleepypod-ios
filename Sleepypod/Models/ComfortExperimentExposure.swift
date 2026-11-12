import Foundation

/// Retained controller evidence stays distinct from a person's morning rating.
struct ComfortExperimentExposure: Decodable, Equatable, Sendable {
    let nightDate: String
    let recordedAt: Int64
    let planHash: String
    let bindingHash: String
    let routineHash: String
    let wakeHash: String
    let sourceHash: String
    let observationWindowId: String?
    let sourceState: String
    let execution: String
    let windowStart: Int64
    let windowEnd: Int64
    let wakeStartsAt: Int64?
    let targetF: Int
    let observedMs: Int64
    let matchedTargetMs: Int64
    let occupiedMs: Int64
    let qualifiedMs: Int64
    let manualChanges: Int
    let unconfirmedCommands: Int
    let safetyInterruptions: Int
    let attributionAmbiguous: Bool
    func validate(updatedAt: Int64) throws {
        try ComfortExperimentContract.require(ComfortExperimentContract.date(nightDate)
            && [recordedAt, windowStart, windowEnd].allSatisfy(ComfortExperimentContract.instant)
            && recordedAt <= updatedAt && recordedAt >= windowEnd && windowEnd > windowStart && windowEnd - windowStart <= 26 * 3_600_000
            && [planHash, bindingHash, routineHash, wakeHash, sourceHash].allSatisfy(ComfortExperimentContract.hash)
            && (observationWindowId.map(ComfortExperimentContract.identifier) ?? true)
            && (wakeStartsAt.map(ComfortExperimentContract.instant) ?? true)
            && ["current", "withdrawn"].contains(sourceState) && ["preview", "active"].contains(execution)
            && ComfortExperimentContract.temperature(targetF)
            && [observedMs, matchedTargetMs, occupiedMs, qualifiedMs].allSatisfy { (0...(26 * 3_600_000)).contains($0) }
            && observedMs <= windowEnd - windowStart && matchedTargetMs <= observedMs && occupiedMs <= observedMs
            && qualifiedMs <= min(matchedTargetMs, occupiedMs)
            && [manualChanges, unconfirmedCommands, safetyInterruptions].allSatisfy { (0...100_000).contains($0) })
    }
}
