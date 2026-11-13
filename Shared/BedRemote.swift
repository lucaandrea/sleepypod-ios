import Foundation

/// Credential-free messages shared by the Watch and iPhone. Commands only use live messaging.
struct BedRemoteRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case refresh, temperature, stopTemperature, stopVibration }
    var version = 1
    var id = UUID()
    var action: Action
    var lease: UUID?
    var issuedAt: Date
    var expiresAt: Date
    var temperatureF: Int?

    init(action: Action, lease: UUID? = nil, temperatureF: Int? = nil, now: Date = .now) {
        self.action = action; self.lease = lease; self.temperatureF = temperatureF
        issuedAt = now; expiresAt = now.addingTimeInterval(15)
    }
    var isStopping: Bool { action == .stopTemperature || action == .stopVibration }
    func validate(at now: Date) throws {
        guard version == 1, issuedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              issuedAt <= now, expiresAt > now, expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 15,
              (action == .refresh) == (lease == nil),
              action == .temperature ? temperatureF.map({ (55...110).contains($0) }) == true : temperatureF == nil else {
            throw BedRemoteFailure.expired
        }
    }
}

struct BedRemoteSnapshot: Codable, Equatable, Sendable {
    struct Zone: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let measuredF: Double?
        let requestedF: Int?
        let powered: Bool?
    }
    let lease: UUID
    let receivedAt: Date
    let expiresAt: Date
    let observationAt: Date?
    let person: String
    let assignment: String
    let zones: [Zone]
    let nextAlarm: String
    let canAdjust: Bool
    let canStop: Bool
    let explanation: String?
    var wake: BedRemoteWake?

    var targetF: Int? {
        guard let target = zones.first?.requestedF, zones.allSatisfy({ $0.requestedF == target }) else { return nil }
        return target
    }
    func isCurrent(at now: Date) -> Bool { receivedAt <= now && now < expiresAt }
    func readingsFresh(at now: Date) -> Bool {
        guard let observationAt else { return false }
        return observationAt <= now && now.timeIntervalSince(observationAt) < 15
    }
    func validate() throws {
        guard receivedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > receivedAt, expiresAt.timeIntervalSince(receivedAt) <= 30,
              !person.isEmpty, person.count <= 80, !assignment.isEmpty, assignment.count <= 100,
              nextAlarm.count <= 500, explanation.map({ $0.count <= 500 }) ?? true,
              !zones.isEmpty, zones.count <= 2, Set(zones.map(\.id)).count == zones.count,
              zones.allSatisfy({ ["left", "right"].contains($0.id)
                  && ($0.measuredF.map { $0.isFinite && (32...140).contains($0) } ?? true)
                  && ($0.requestedF.map { (55...110).contains($0) } ?? true) }),
              observationAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= receivedAt }) ?? true,
              wake.map({ $0.valid(checkedAt: receivedAt) }) ?? true,
              !canAdjust || (readingsFresh(at: receivedAt) && canStop) else { throw BedRemoteFailure.invalid }
    }
}

/// An absolute occurrence avoids retaining relative phrases such as "tomorrow" across midnight.
struct BedRemoteWake: Codable, Equatable, Sendable {
    let side: String
    let at: Date
    let timeZone: String
    let warmingAt: Date?
    let targetF: Double?
    let vibrationSeconds: Double

    func valid(checkedAt: Date) -> Bool {
        ["left", "right"].contains(side) && TimeZone(identifier: timeZone) != nil
            && at.timeIntervalSince1970.isFinite && at > checkedAt && at.timeIntervalSince(checkedAt) <= 8 * 86_400
            && vibrationSeconds.isFinite && (0...3_600).contains(vibrationSeconds)
            && (warmingAt == nil) == (targetF == nil)
            && (warmingAt.map { $0.timeIntervalSince1970.isFinite && $0 < at } ?? true)
            && (targetF.map { $0.isFinite && (55...110).contains($0) } ?? true)
    }
    var timeLabel: String { format(at, date: false) }
    var dateLabel: String { format(at, date: true) }
    var warmingLabel: String? { warmingAt.map { format($0, date: false) } }
    private func format(_ instant: Date, date: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateStyle = date ? .medium : .none
        formatter.timeStyle = date ? .none : .short
        return formatter.string(from: instant)
    }
}

struct BedRemoteReply: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case snapshot, acknowledged, withheld, uncertain }
    let requestID: UUID
    let outcome: Outcome
    let snapshot: BedRemoteSnapshot?
    let message: String
}

enum BedRemoteFailure: Error, LocalizedError {
    case expired, changed, invalid, unavailable, busy
    var errorDescription: String? {
        switch self {
        case .expired: "That request expired. Refresh the bed before trying again."
        case .changed: "Your account, bed side or target changed. Refresh and review it."
        case .invalid: "The bed reply could not be verified. Open sleepypod on iPhone."
        case .unavailable: "The bed is unavailable. Open sleepypod on iPhone to check the connection."
        case .busy: "An adjustment is already in progress. Stop remains available."
        }
    }
}
