import Foundation

struct ComfortLimitConfiguration: Codable, Sendable, Equatable {
    var enabled: Bool
    var minF: Int
    var maxF: Int
    var isValid: Bool { (55...110).contains(minF) && (55...110).contains(maxF) && minF <= maxF && maxF - minF <= 10 }
}

struct ComfortLimitPage: Codable, Sendable, Equatable {
    let apiVersion: Int
    let side: Side
    let sourceSide: Side
    let revision: Int
    let config: ComfortLimitConfiguration
    let wake: Wake?
    let wakeAvailable: Bool

    struct Wake: Codable, Sendable, Equatable {
        let startsAt: Double
        let alarmAt: Double
        let targetF: Double
        let timeZone: String
        var startsDate: Date { Date(timeIntervalSince1970: startsAt / 1000) }
    }
    func validate(for requestedSide: Side) throws {
        guard apiVersion == 1, side == requestedSide, revision >= 0, revision <= 9_007_199_254_740_991, config.isValid else {
            throw ComfortLimitError.invalidResponse
        }
        if let wake {
            guard wakeAvailable, wake.startsAt.isFinite, wake.alarmAt.isFinite,
                  wake.startsAt >= 0, wake.alarmAt <= 8_640_000_000_000_000,
                  wake.startsAt <= wake.alarmAt, wake.alarmAt - wake.startsAt <= 120 * 60_000,
                  (55...110).contains(wake.targetF), TimeZone(identifier: wake.timeZone) != nil else {
                throw ComfortLimitError.invalidResponse
            }
        }
    }
}

struct ComfortLimitWrite: Codable, Sendable, Equatable {
    let side: Side
    let expectedSourceSide: Side
    let expectedRevision: Int
    let config: ComfortLimitConfiguration
}

enum ComfortLimitError: Error { case invalidResponse, staleDraft }

struct ComfortLimitDecision: Codable, Sendable, Equatable {
    let state: String
    let requestedF: Double
    let targetF: Double?
    let minF: Double?
    let maxF: Double?
    let revision: Int?
    let wakeUntil: Double?
    var explanation: String? {
        switch state {
        case "limited": "Requested \(requestedF.formatted())°F · limited to \(targetF?.formatted() ?? "—")°F by your comfort range."
        case "wake": "Wake warming · your saved alarm temporarily permits this higher target."
        case "manual" where (revision ?? 0) > 0: "Manual hold · automatic limits resume when this hold ends."
        case "unavailable": "Automatic target withheld: the saved comfort limit could not be read."
        default: nil
        }
    }
}
