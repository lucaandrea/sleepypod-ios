import Foundation

/// A preview and durable lease for one physical zone. It never identifies a sleeper.
struct TemporaryCooling: Codable, Sendable, Equatable {
    struct Proposal: Codable, Sendable, Equatable {
        let scope: String
        let fromTargetF: Int
        let targetF: Int
        let expiresAt: Int64
        func validate() throws {
            guard scope.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  (55...110).contains(fromTargetF), (55...110).contains(targetF),
                  (1...2).contains(fromTargetF - targetF), TemporaryCooling.validTime(expiresAt) else { throw NativeControlFailure.invalid }
        }
    }
    struct Lease: Codable, Sendable, Equatable {
        let version: Int
        let id: String
        let side: Side
        let scope: String
        let fromTargetF: Int
        let targetF: Int
        let startedAt: Int64
        let expiresAt: Int64
        let sessionEndsAt: Int64
        let phase: String
        func validate(for expected: Side) throws {
            try Proposal(scope: scope, fromTargetF: fromTargetF, targetF: targetF, expiresAt: expiresAt).validate()
            guard version == 1, UUID(uuidString: id) != nil, side == expected,
                  TemporaryCooling.validTime(startedAt), TemporaryCooling.validTime(sessionEndsAt),
                  expiresAt > startedAt, expiresAt - startedAt <= 1_200_000, sessionEndsAt >= expiresAt,
                  ["prepared", "active", "returning", "unknown"].contains(phase) else { throw NativeControlFailure.invalid }
        }
    }
    let apiVersion: Int
    let side: Side
    let generatedAt: Int64
    let state: String
    let reason: String
    let observedAt: Int64?
    let proposal: Proposal?
    let lease: Lease?
    let physicalVerification: String
    func validate(for expected: Side) throws {
        guard apiVersion == 1, side == expected, Self.validTime(generatedAt),
              observedAt.map({ Self.validTime($0) && $0 <= generatedAt }) ?? true, reason.count <= 2000,
              ["ready", "cooling", "waiting", "unknown", "unavailable"].contains(state),
              physicalVerification == "unverified", proposal == nil || lease == nil,
              (state == "ready") == (proposal != nil),
              state != "cooling" || lease?.phase == "active" else { throw NativeControlFailure.invalid }
        try proposal?.validate(); try lease?.validate(for: expected)
        if let proposal {
            guard proposal.expiresAt > generatedAt, proposal.expiresAt - generatedAt <= 1_200_000 else { throw NativeControlFailure.invalid }
        }
    }
    func current(at date: Date) -> Bool {
        let now = date.timeIntervalSince1970 * 1000
        return (try? validate(for: side)) != nil && Double(generatedAt) <= now && now - Double(generatedAt) < 20_000
    }
    func matches(_ preview: Proposal, at date: Date) -> Bool {
        guard current(at: date), state == "ready", let proposal else { return false }
        return preview.scope == proposal.scope && preview.fromTargetF == proposal.fromTargetF
            && preview.targetF == proposal.targetF && preview.expiresAt <= proposal.expiresAt
            && Double(preview.expiresAt) - date.timeIntervalSince1970 * 1000 >= 60_000
    }
    static func validTime(_ value: Int64) -> Bool { value >= 0 && value <= 8_640_000_000_000_000 }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}
