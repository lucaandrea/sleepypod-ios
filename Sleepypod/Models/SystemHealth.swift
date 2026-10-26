import Foundation

enum HealthCheckStatus: String, Codable, Sendable {
    case ok, idle, stale, down, unknown
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
    var title: String {
        switch self {
        case .ok: "Flowing"
        case .idle: "Idle"
        case .stale: "Stalled"
        case .down: "Down"
        case .unknown: "Unknown"
        }
    }
    var rank: Int {
        switch self {
        case .down: 4
        case .stale: 3
        case .ok: 2
        case .idle: 1
        case .unknown: 0
        }
    }
}

struct SystemHealthPath: Decodable, Sendable {
    struct Node: Decodable, Sendable, Identifiable {
        let id: String
        let stage: String
        let label: String
        let status: HealthCheckStatus
        let metric: String
        let detail: String
        let lastOutputAt: Double?
        let unit: String?
        let path: String?
    }
    struct Edge: Decodable, Sendable { let from: String; let to: String; let state: String }
    struct Fix: Decodable, Sendable {
        let kind: String
        let unit: String?
        let label: String
        let sides: [Side]?
        let hint: String?
        let tab: String?
    }
    struct Verdict: Decodable, Sendable {
        let tone: String
        let headline: String
        let nodeId: String?
        let lastGoodId: String?
        let fix: Fix?
        let also: [String]
    }
    let at: Double
    let occupancy: [String: String]
    let nodes: [Node]
    let edges: [Edge]
    let verdict: Verdict
    static let stages = ["sensors", "hardware", "services", "core", "outputs"]
    static let restartableUnits = Set(["sleepypod-piezo-processor.service", "sleepypod-sleep-detector.service", "sleepypod-environment-monitor.service"])
    var orderedStages: [String] { Self.stages + Set(nodes.map(\.stage)).subtracting(Self.stages).sorted() }
    func label(_ id: String) -> String { nodes.first { $0.id == id }?.label ?? id }
    static func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }
}

struct SystemHealthHistory: Decodable, Sendable {
    struct Run: Codable, Hashable, Sendable { let status: HealthCheckStatus; let start: Double; var end: Double }
    struct Check: Decodable, Sendable, Identifiable {
        let id: String
        let label: String
        let runs: [Run]
        let healthyShare: Double?
        let incidents: Int
    }
    struct Incident: Decodable, Sendable {
        let checkId: String
        let label: String
        let status: HealthCheckStatus
        let start: Double
        let end: Double?
        let detail: String?
    }
    struct Gap: Decodable, Sendable { let start: Double; let end: Double }
    struct Row: Sendable, Identifiable {
        let id: String
        let label: String
        let runs: [Run]
        let healthyShare: Double?
        let incidents: Int
        var collapsed = false
    }
    struct IncidentLine: Sendable, Identifiable {
        let id: String
        let title: String
        let status: HealthCheckStatus
        let start: Double
        let end: Double?
        let tag: String?
        let detail: String?
    }
    let from: Double
    let to: Double
    let recordedSince: Double?
    let checks: [Check]
    let incidents: [Incident]
    let gaps: [Gap]

    func rows(all: Bool) -> [Row] {
        if all { return checks.map { .init(id: $0.id, label: $0.label, runs: $0.runs, healthyShare: $0.healthyShare, incidents: $0.incidents) } }
        let affected = checks.filter { $0.incidents > 0 }, rest = checks.filter { $0.incidents == 0 }
        var groups: [[Check]] = []
        for check in affected {
            if let index = groups.firstIndex(where: { $0.first?.runs == check.runs }) { groups[index].append(check) }
            else { groups.append([check]) }
        }
        var result = groups.compactMap { group -> Row? in
            guard let first = group.first else { return nil }
            return .init(id: group.map(\.id).joined(separator: "+"), label: group.map(\.label).joined(separator: " · "), runs: first.runs, healthyShare: first.healthyShare, incidents: group.map(\.incidents).max() ?? 0)
        }
        if rest.count == 1, let check = rest.first {
            result.append(.init(id: check.id, label: check.label, runs: check.runs, healthyShare: check.healthyShare, incidents: 0))
        } else if rest.count > 1 {
            result.append(.init(id: "rest", label: "\(rest.count) other checks", runs: Self.mergedRuns(rest.map(\.runs)), healthyShare: rest.compactMap(\.healthyShare).min(), incidents: 0, collapsed: true))
        }
        return result
    }

    // Sweep interval boundaries once per check. Missing recording time is never filled with a healthy result.
    static func mergedRuns(_ input: [[Run]]) -> [Run] {
        let groups = input.map { $0.filter { $0.end > $0.start }.sorted { $0.start < $1.start } }
        let boundaries = Set(groups.flatMap { $0.flatMap { [$0.start, $0.end] } }).sorted()
        guard boundaries.count > 1 else { return [] }
        var positions = Array(repeating: 0, count: groups.count), result: [Run] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index], end = boundaries[index + 1]
            var worst: HealthCheckStatus?
            for group in groups.indices {
                while positions[group] < groups[group].count && groups[group][positions[group]].end <= start { positions[group] += 1 }
                guard positions[group] < groups[group].count else { continue }
                let run = groups[group][positions[group]]
                if run.start <= start, worst == nil || run.status.rank > worst!.rank { worst = run.status }
            }
            guard let worst else { continue }
            if let last = result.last, last.status == worst, last.end == start { result[result.count - 1].end = end }
            else { result.append(.init(status: worst, start: start, end: end)) }
        }
        return result
    }

    var incidentLines: [IncidentLine] {
        var groups: [[Incident]] = []
        for incident in incidents {
            if let index = groups.firstIndex(where: { $0.first?.start == incident.start && $0.first?.end == incident.end }) { groups[index].append(incident) }
            else { groups.append([incident]) }
        }
        var lines = groups.compactMap { group -> IncidentLine? in
            guard let first = group.first else { return nil }
            let status: HealthCheckStatus = group.contains { $0.status == .down } ? .down : .stale
            let recurring = group.contains { incident in checks.contains { $0.id == incident.checkId && $0.incidents >= 3 } }
            let tag = first.end == nil ? "Ongoing" : recurring ? "Recurring" : (first.end! - first.start < 300_000 ? "Brief" : nil)
            return .init(id: "\(first.checkId)-\(first.start)", title: "\(group.map(\.label).joined(separator: " · ")) \(status.title.lowercased())", status: status, start: first.start, end: first.end, tag: tag, detail: first.detail)
        }
        lines += gaps.filter { $0.end > $0.start }.map { .init(id: "gap-\($0.start)", title: "Not recorded", status: .unknown, start: $0.start, end: $0.end, tag: nil, detail: "No checks were recorded in this interval.") }
        return lines.sorted { ($0.end ?? to) > ($1.end ?? to) }
    }
}

struct HealthServiceRestart: Decodable, Sendable { let ok: Bool; let message: String }
