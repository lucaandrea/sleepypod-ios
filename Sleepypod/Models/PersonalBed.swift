import Foundation

struct PersonalControlScope: Codable, Equatable, Sendable {
    let podId: String
    let householdId: String
    let sleeperId: String
    let sessionRevision: Int
    let assignmentRevision: Int
    let configurationRevision: String

    func validate() throws {
        guard [podId, householdId, sleeperId].allSatisfy(HouseholdValidation.identifier),
              [sessionRevision, assignmentRevision].allSatisfy(HouseholdValidation.revision),
              configurationRevision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw HouseholdFailure.invalid }
    }
    func matches(_ session: HouseholdSession) -> Bool {
        podId == session.podId && householdId == session.householdId && sleeperId == session.selfSleeperId
            && sessionRevision == session.sessionRevision && assignmentRevision == session.assignmentRevision
    }
    func belongs(to session: HouseholdSession) -> Bool {
        podId == session.podId && householdId == session.householdId && sleeperId == session.selfSleeperId
    }
}

struct PersonalBed: Codable, Equatable, Sendable {
    struct Routing: Codable, Equatable, Sendable {
        let temperature: [Side]
        let power: [Side]
        let vibrationCancellation: [Side]
        let scheduledVibration: [Side]
        let routines: Side?
        var lists: [[Side]] { [temperature, power, vibrationCancellation, scheduledVibration] }
        func zones(for action: PersonalControlAction) -> [Side] {
            switch action.kind {
            case "temperature": temperature
            case "power": power
            default: vibrationCancellation
            }
        }
    }
    struct Observation: Codable, Equatable, Sendable {
        let state: String
        let observedAt: Int64?
        let water: String
        let priming: Bool?
        func isFresh(at now: Date) -> Bool {
            guard state == "fresh", let observedAt else { return false }
            let age = now.timeIntervalSince1970 * 1_000 - Double(observedAt)
            return age >= 0 && age < 15_000
        }
    }
    struct Zone: Codable, Equatable, Identifiable, Sendable {
        let side: Side
        let measuredTemperatureF: Double?
        let reportedTargetF: Double?
        let reportedPowered: Bool?
        let requestedTargetF: Double?
        var id: Side { side }
        var withoutObservation: Self {
            .init(side: side, measuredTemperatureF: nil, reportedTargetF: nil, reportedPowered: nil, requestedTargetF: requestedTargetF)
        }
    }
    let version: Int
    let scope: PersonalControlScope
    let arrangement: String
    let availability: String
    let routing: Routing
    let observation: Observation
    let zones: [Zone]
    let physicalVerification: String

    /// A ready response must describe exactly this person's authorized zones; unavailable states expose none.
    func validate(for session: HouseholdSession) throws {
        try session.validate(); try scope.validate()
        guard scope.matches(session), arrangement == session.arrangement.mode else { throw HouseholdFailure.changedIdentity }
        guard version == 1, physicalVerification == "unverified",
              ["ready", "unassigned", "configuration_changed", "runtime_disabled"].contains(availability),
              ["fresh", "unavailable"].contains(observation.state), ["ok", "low", "unknown"].contains(observation.water),
              observation.observedAt.map(PersonalControlRequest.validInstant) ?? true,
              routing.lists.allSatisfy({ $0.count <= 2 && Set($0).count == $0.count }), routing.scheduledVibration.count <= 1,
              zones.count <= 2, Set(zones.map(\.side)).count == zones.count else { throw HouseholdFailure.invalid }
        for zone in zones {
            guard [zone.measuredTemperatureF, zone.reportedTargetF].allSatisfy({ $0.map { $0.isFinite && (32...140).contains($0) } ?? true }),
                  zone.requestedTargetF.map({ $0.isFinite && (55...110).contains($0) }) ?? true else { throw HouseholdFailure.invalid }
        }
        if availability == "ready" {
            let permitted = Set(session.person.zones)
            guard session.capabilities.personalControls, !permitted.isEmpty,
                  Set(zones.map(\.side)) == permitted,
                  [routing.temperature, routing.power, routing.vibrationCancellation].allSatisfy({ Set($0) == permitted }),
                  let source = routing.routines, permitted.contains(source), routing.scheduledVibration == [source] else { throw HouseholdFailure.invalid }
        } else {
            guard zones.isEmpty, routing.lists.allSatisfy(\.isEmpty), routing.routines == nil,
                  observation.state == "unavailable" else { throw HouseholdFailure.invalid }
        }
        if observation.state == "unavailable" {
            guard observation.observedAt == nil, observation.water == "unknown", observation.priming == nil,
                  zones.allSatisfy({ $0.measuredTemperatureF == nil && $0.reportedTargetF == nil && $0.reportedPowered == nil }) else { throw HouseholdFailure.invalid }
        } else if observation.observedAt == nil { throw HouseholdFailure.invalid }
    }
}
