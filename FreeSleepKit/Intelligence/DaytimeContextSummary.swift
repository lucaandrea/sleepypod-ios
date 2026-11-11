import Foundation

struct DaytimeContextSummary: Sendable, Equatable {
    struct Group: Sendable, Equatable {
        var kind: DaytimeContext.Kind
        var source: DaytimeContext.Source
        var observationCount: Int
        var total: Double?
        var latestEnd: Date?
        var excludedOverlaps: Int
    }
    struct Wrist: Sendable, Equatable {
        var source: DaytimeContext.Source
        var start: Date
        var end: Date
        var absoluteCelsius: Double
    }
    var windowStart: Date
    var bedtime: Date
    var importedAt: Date
    var groups: [Group]
    var previousWrist: [Wrist]
    var unavailableKinds: [DaytimeContext.Kind]
    var emptyKinds: [DaytimeContext.Kind]

    /// The preceding 24 elapsed hours work across DST and travel without inventing a local calendar day.
    static func make(snapshot: DaytimeContext, bedtime: Date, now: Date = .now) throws -> Self {
        try snapshot.validate()
        guard now.timeIntervalSince1970.isFinite, bedtime.timeIntervalSince1970.isFinite,
              bedtime.timeIntervalSince1970 > 86_400, bedtime <= now, snapshot.importedAt <= now else {
            throw DaytimeContextError.invalidSnapshot
        }
        let start = bedtime.addingTimeInterval(-86_400)
        let unavailable = snapshot.reads.filter { $0.state == .unavailable || $0.start > start || $0.end < bedtime }.map(\.kind)
        let unique = Array(Dictionary(snapshot.observations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        let observations = unique.filter { $0.start >= start && $0.end <= bedtime && $0.kind != .sleepingWristCelsius
            && !unavailable.contains($0.kind) }
        var groups: [Group] = []
        let kinds = DaytimeContext.Kind.allCases.filter { $0 != .sleepingWristCelsius }
        for kind in kinds {
            let candidates = observations.filter { $0.kind == kind }
            let sources = Dictionary(grouping: candidates, by: \.source)
            // Never sum two devices/apps into a person's artificial activity total.
            for source in sources.keys.sorted(by: sourceOrder) {
                let values = (sources[source] ?? []).sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
                let excluded = overlappingIDs(values)
                let included = values.filter { !excluded.contains($0.id) }
                groups.append(.init(kind: kind, source: source, observationCount: included.count,
                    total: included.isEmpty ? nil : included.reduce(0) { $0 + $1.value },
                    latestEnd: included.map(\.end).max(), excludedOverlaps: excluded.count))
            }
        }
        // A same-night wrist aggregate only exists after that night; it cannot predict its own bedtime.
        let wristCandidates = unique.filter { $0.kind == .sleepingWristCelsius && !unavailable.contains($0.kind) && $0.end <= bedtime
            && $0.start >= bedtime.addingTimeInterval(-7 * 86_400) }
        let wristSources = Dictionary(grouping: wristCandidates, by: \.source)
        let previousWrist = wristSources.keys.sorted(by: sourceOrder).compactMap { source -> Wrist? in
            let sourceValues = wristSources[source] ?? []
            let excluded = overlappingIDs(sourceValues.sorted { $0.start < $1.start })
            guard let latest = sourceValues.filter({ !excluded.contains($0.id) }).max(by: { $0.end < $1.end }) else { return nil }
            return .init(source: source, start: latest.start, end: latest.end, absoluteCelsius: latest.value)
        }
        let empty = kinds.filter { kind in !unavailable.contains(kind) && !groups.contains(where: { $0.kind == kind }) }
        return .init(windowStart: start, bedtime: bedtime, importedAt: snapshot.importedAt, groups: groups,
                     previousWrist: previousWrist, unavailableKinds: unavailable, emptyKinds: empty)
    }

    private static func sourceOrder(_ first: DaytimeContext.Source, _ second: DaytimeContext.Source) -> Bool {
        [first.identifier, first.deviceIdentifier ?? "", first.device ?? "", first.name]
            .lexicographicallyPrecedes([second.identifier, second.deviceIdentifier ?? "", second.device ?? "", second.name])
    }

    /// Exclude every member of an overlapping component. Adjacent samples remain separate observations.
    private static func overlappingIDs(_ values: [DaytimeContext.Observation]) -> Set<UUID> {
        var excluded = Set<UUID>()
        var componentEnd = Date.distantPast
        var previousID: UUID?
        var previousStart = Date.distantPast
        var previousWasPoint = false
        for observation in values {
            let sharedPoint = previousWasPoint && observation.start == previousStart
            if observation.start < componentEnd || sharedPoint, let previousID {
                excluded.insert(previousID); excluded.insert(observation.id)
                componentEnd = max(componentEnd, observation.end)
            } else { componentEnd = observation.end }
            previousID = observation.id
            previousStart = observation.start
            previousWasPoint = observation.start == observation.end
        }
        return excluded
    }
}
