import Foundation

struct TemperatureApplication: Codable, Identifiable, Sendable, Equatable {
    enum Outcome: String, Codable, Sendable { case attempting, acknowledged, unknown }
    enum Reason: String, Codable, Sendable {
        case manual, powerOn = "power_on", reconcile, keepalive
        var label: String {
            switch self {
            case .manual: "Manual adjustment"
            case .powerOn: "Power on"
            case .reconcile: "Target reconciliation"
            case .keepalive: "Target refresh"
            }
        }
    }
    let id: Int
    let attemptId: UUID
    let side: Side
    let attemptedAt: Double
    let finishedAt: Double?
    let outcome: Outcome
    let acknowledgment: String
    let reason: Reason
    let source: String?
    let requestId: String?
    let targetF: Double
    let durationSec: Int?
    var date: Date { Date(timeIntervalSince1970: attemptedAt / 1000) }
    var label: String { outcome == .acknowledged ? "Accepted · physically unverified" : "Unconfirmed" }
    var detail: String {
        switch outcome {
        case .acknowledged: "The controller call completed. This does not confirm the measured bed temperature."
        case .attempting: "An attempt was recorded without a final result. It may have been interrupted."
        case .unknown: "The controller could not confirm this attempt's outcome."
        }
    }
    func validate(side: Side) throws {
        guard self.side == side, (1...9_007_199_254_740_991).contains(id), Self.validTime(attemptedAt),
              finishedAt.map({ Self.validTime($0) && $0 >= attemptedAt }) ?? true,
              outcome != .acknowledged || finishedAt != nil,
              outcome != .attempting || finishedAt == nil,
              acknowledgment == (outcome == .acknowledged ? "accepted_not_physically_verified" : "unconfirmed"),
              targetF.isFinite, (55...110).contains(targetF), durationSec.map({ (0...9_007_199_254_740_991).contains($0) }) ?? true,
              source.map({ ["manual", "run-once", "autopilot", "schedule"].contains($0) }) ?? true,
              requestId.map({ !$0.isEmpty && $0.count <= 2000 }) ?? true else { throw TemperatureApplicationPage.invalid }
    }
    static func validTime(_ value: Double) -> Bool { value.isFinite && value.rounded() == value && (0...8_640_000_000_000_000).contains(value) }
}
struct TemperatureApplicationPage: Codable, Sendable {
    let apiVersion: Int
    let generatedAt: Double
    let side: Side
    let items: [TemperatureApplication]
    let nextBeforeId: Int?
    static var invalid: APIError { .serverError(message: "The temperature application history did not match this side or page. Refresh before continuing.") }
    func validate(side: Side, before: Int? = nil) throws {
        guard apiVersion == 1, self.side == side, TemperatureApplication.validTime(generatedAt), items.count <= 50,
              Set(items.map(\.id)).count == items.count, Set(items.map(\.attemptId)).count == items.count,
              items.map(\.id) == items.map(\.id).sorted(by: >) else { throw Self.invalid }
        for item in items { try item.validate(side: side); if let before, item.id >= before { throw Self.invalid } }
        if let nextBeforeId {
            guard items.count == 50, nextBeforeId == items.last?.id, before.map({ nextBeforeId < $0 }) ?? true else { throw Self.invalid }
        }
    }
}
