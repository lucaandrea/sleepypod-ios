import Foundation

struct BiometricObservationTemplate: Codable, Sendable, Identifiable {
    let id: String
    let label: String
    let maximumWindowMs: Double
}
struct BiometricObservationTemplates: Codable, Sendable { let items: [BiometricObservationTemplate] }
struct BiometricObservationPreparation: Codable, Equatable, Sendable {
    let templateId: String
    let side: Side
    let subjectId: String
    let candidateRevisionId: String?
    let startMs: Double
    let endMs: Double
    var body: JSONValue {
        .object(["templateId": .string(templateId), "side": .string(side.rawValue), "subjectId": .string(subjectId),
                 "candidateRevisionId": candidateRevisionId.map(JSONValue.string) ?? .null,
                 "startMs": .number(startMs), "endMs": .number(endMs)])
    }
    func validate(maximumWindowMs: Double, now: Date = .now) throws {
        if let candidateRevisionId { _ = try BiometricBacktestInput.identifier(candidateRevisionId) }
        guard (1...80).contains(templateId.utf16.count), (1...200).contains(subjectId.utf16.count), !subjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              startMs.isFinite, endMs.isFinite, startMs.rounded() == startMs, endMs.rounded() == endMs,
              startMs > now.timeIntervalSince1970 * 1000, endMs > startMs, endMs < 9_007_199_254_740_991,
              endMs - startMs <= min(maximumWindowMs, 604800000) else {
            throw BiometricBacktestInput.error("Choose a saved template, sleeper identity and future UTC window within the template limit.")
        }
    }
}
/// Preserve the server's complete plan, including nested qualification and resource limits, for exact retry.
struct BiometricObservationPrepared: Codable, Equatable, Sendable {
    let status: String
    let plan: JSONValue
    let planHash: String
    func validate(for input: BiometricObservationPreparation) throws {
        guard status == "prepared_not_admitted", BiometricBacktestInput.isHash(planHash),
              plan["schema"] == .string("biometric-shadow-plan-v1"), plan["side"] == .string(input.side.rawValue),
              plan["subjectId"] == .string(input.subjectId), plan["startMs"] == .number(input.startMs), plan["endMs"] == .number(input.endMs),
              plan["candidateRevisionId"] == (input.candidateRevisionId.map(JSONValue.string) ?? .null),
              ["candidateConfigHash", "activeConfigHash", "qualificationHash", "engineBuildHash"].allSatisfy({ BiometricBacktestInput.isHash(plan[$0]?.string ?? "") }),
              plan["execution"]?["version"] == .string("shadow-execution-policy-v1"),
              plan["execution"]?["configHashes"]?[input.side.rawValue] == plan["candidateConfigHash"],
              Side.allCases.allSatisfy({ side in
                  let binding = plan["expectedBindings"]?[side.rawValue]
                  return (binding?["generation"]?.number ?? 0) >= 1 && BiometricBacktestInput.isHash(binding?["resolvedHash"]?.string ?? "")
              }), try JSONEncoder().encode(plan).count <= 65536 else {
            throw BiometricBacktestInput.error("The prepared observation does not match the selected candidate and window. Prepare it again.")
        }
    }
    func matches(_ run: BiometricObservationRun) -> Bool {
        run.planHash == planHash && plan["side"] == .string(run.side.rawValue) && plan["subjectId"] == .string(run.subjectId)
            && plan["startMs"] == .number(run.startMs) && plan["endMs"] == .number(run.endMs)
            && plan["candidateConfigHash"] == .string(run.candidateConfigHash) && plan["activeConfigHash"] == .string(run.activeConfigHash)
            && run.candidateIdentitySaved && plan["candidateRevisionId"] == (run.candidateRevisionId.map(JSONValue.string) ?? .null)
    }
}
struct BiometricObservationSubmission: Codable, Equatable, Sendable {
    let prepared: BiometricObservationPrepared
    let idempotencyKey: String
    var side: Side? { prepared.plan["side"]?.string.flatMap(Side.init(rawValue:)) }
    func body() throws -> JSONValue {
        guard side != nil, (1...200).contains(idempotencyKey.utf16.count), BiometricBacktestInput.isHash(prepared.planHash) else {
            throw BiometricBacktestInput.error("The retained observation request is invalid.")
        }
        return .object(["plan": prepared.plan, "idempotencyKey": .string(idempotencyKey)])
    }
}
enum BiometricObservationState: String, Codable, Sendable {
    case pending, running, completed, stopped, failed
    var isActive: Bool { self == .pending || self == .running }
    var title: String {
        switch self {
        case .pending: "Scheduled"
        case .running: "Observing"
        case .completed: "Execution completed"
        case .stopped: "Stop recorded"
        case .failed: "Failed"
        }
    }
}
struct BiometricObservationRun: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let side: Side
    let subjectId: String
    let state: BiometricObservationState
    let planHash: String
    let candidateConfigHash: String
    let activeConfigHash: String
    let candidateRevisionId: String?
    let candidateIdentitySaved: Bool
    let startMs: Double
    let endMs: Double
    let createdAtMs: Double
    let endedAtMs: Double?
    let heartbeatAtMs: Double?
    let reason: String?
    let pointCount: Int
    let byteCount: Int
    let workerReceiptAvailable: Bool
    func validate(matching selected: Self) throws {
        try validate(side: selected.side, id: selected.id, planHash: selected.planHash)
        guard subjectId == selected.subjectId, startMs == selected.startMs, endMs == selected.endMs,
              candidateConfigHash == selected.candidateConfigHash, activeConfigHash == selected.activeConfigHash,
              candidateRevisionId == selected.candidateRevisionId, candidateIdentitySaved == selected.candidateIdentitySaved else {
            throw BiometricBacktestInput.error("The observation response changed its saved input identity.")
        }
    }
    func validate(side: Side, id: String? = nil, planHash: String? = nil) throws {
        _ = try BiometricBacktestInput.identifier(self.id)
        guard self.side == side, id == nil || self.id == id, planHash == nil || self.planHash == planHash,
              [self.planHash, candidateConfigHash, activeConfigHash].allSatisfy(BiometricBacktestInput.isHash),
              startMs.isFinite, endMs.isFinite, startMs >= 0, endMs > startMs, pointCount >= 0, byteCount >= 0 else {
            throw BiometricBacktestInput.error("The observation response does not match this selection.")
        }
    }
}
struct BiometricObservationPage: Codable, Sendable { let items: [BiometricObservationRun]; let nextCursor: String? }
struct BiometricObservationStop: Codable, Sendable { let run: BiometricObservationRun; let localAttemptSettled: Bool }
