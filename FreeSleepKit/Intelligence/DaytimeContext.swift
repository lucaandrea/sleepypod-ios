import Foundation

/// Optional Health observations, kept separate from sleep labels and actuator inputs.
struct DaytimeContext: Codable, Sendable, Equatable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case workout, exerciseMinutes, activeEnergyKilocalories, steps, sleepingWristCelsius
    }
    struct Source: Codable, Hashable, Sendable {
        var identifier: String
        var name: String
        var device: String?
        /// HealthKit-local identity keeps two devices of the same model separate.
        var deviceIdentifier: String?
    }
    struct Observation: Codable, Identifiable, Sendable, Equatable {
        var id: UUID
        var kind: Kind
        var source: Source
        var start: Date
        var end: Date
        /// Workout and exercise duration use minutes; other units are named by Kind.
        var value: Double
        var workoutActivity: UInt?
        var recordedTimeZone: String?
    }
    struct Read: Codable, Sendable, Equatable {
        enum State: String, Codable, Sendable { case completed, unavailable }
        var kind: Kind
        var state: State
        var start: Date
        var end: Date
    }
    var importedAt: Date
    var timeZone: String
    var reads: [Read]
    var observations: [Observation]

    func validate() throws {
        guard importedAt.timeIntervalSince1970.isFinite, importedAt.timeIntervalSince1970 > 0,
              TimeZone(identifier: timeZone) != nil,
              Set(reads.map(\.kind)).count == reads.count, reads.count == Kind.allCases.count,
              observations.count <= 200_000 else { throw DaytimeContextError.invalidSnapshot }
        for read in reads {
            guard read.start.timeIntervalSince1970.isFinite, read.start.timeIntervalSince1970 > 0,
                  read.start < read.end, read.end <= importedAt else { throw DaytimeContextError.invalidSnapshot }
        }
        // Conflicting duplicates are rejected rather than silently choosing one source or value.
        var seen: [UUID: Observation] = [:]
        for observation in observations {
            guard let read = reads.first(where: { $0.kind == observation.kind }), read.state == .completed,
                  observation.start >= read.start, observation.start <= observation.end, observation.end <= read.end,
                  observation.start.timeIntervalSince1970.isFinite, observation.end.timeIntervalSince1970.isFinite,
                  observation.value.isFinite, observation.value >= 0, observation.value <= 1_000_000_000,
                  !observation.source.identifier.isEmpty, observation.source.identifier.count <= 500,
                  !observation.source.name.isEmpty, observation.source.name.count <= 500,
                  (observation.source.device?.count ?? 0) <= 500,
                  observation.source.deviceIdentifier.map({ !$0.isEmpty && $0.count <= 500 }) ?? true,
                  observation.recordedTimeZone.map({ TimeZone(identifier: $0) != nil }) ?? true,
                  observation.kind == .workout || observation.workoutActivity == nil,
                  observation.kind != .workout || observation.start < observation.end,
                  observation.kind != .workout || observation.value <= observation.end.timeIntervalSince(observation.start) / 60 + 0.02,
                  seen[observation.id].map({ $0 == observation }) ?? true else { throw DaytimeContextError.invalidSnapshot }
            seen[observation.id] = observation
        }
    }
}

enum DaytimeContextError: Error { case invalidSnapshot, changedIdentity, unavailable }

struct DaytimeContextArchive: Codable, Sendable, Equatable {
    var version = 1
    var enabled = false
    var snapshot: DaytimeContext?
}
