import Foundation

enum AutomationEvaluationKind: String, Codable, Sendable {
    case none, missing, skipped, cooldown, error, would, fired
    var rank: Int {
        switch self {
        case .none: 0
        case .missing: 1
        case .skipped: 2
        case .cooldown: 3
        case .error: 4
        case .would: 5
        case .fired: 6
        }
    }
    var label: String {
        switch self {
        case .none: "No evaluation"
        case .missing: "No evaluation logged"
        case .skipped: "Skipped"
        case .cooldown: "Cooldown"
        case .error: "Error"
        case .would: "Would fire"
        case .fired: "Fired / clamped"
        }
    }
    static func from(_ run: AutomationDiagnostics.Run) -> Self {
        switch run.outcome {
        case "dry_run": .would
        case "fired", "clamped": .fired
        case "error": .error
        default: run.reason == "cooldown" ? .cooldown : .skipped
        }
    }
}
enum AutomationEvaluationFilter: String, CaseIterable, Identifiable, Sendable {
    case all, would, fired, skipped, missing
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func matches(_ kind: AutomationEvaluationKind) -> Bool {
        switch self {
        case .all: kind != .none
        case .would: kind == .would
        case .fired: kind == .fired
        case .skipped: kind == .skipped || kind == .cooldown
        case .missing: kind == .missing
        }
    }
}
struct AutomationEvaluationStripData: Codable, Equatable, Sendable {
    let startMs: Double
    let endMs: Double
    let ticks: [AutomationEvaluationKind]
    let cooldowns: [[Int]]
}
struct AutomationEvaluationGroup: Codable, Equatable, Sendable {
    let kind: AutomationEvaluationKind
    let reason: String?
    var count: Int
    var firstMs: Double
    let lastMs: Double
    var sent: Int
}
struct AutomationEvaluationLog: Sendable {
    struct TimedRun: Sendable { let at: Double; let run: AutomationDiagnostics.Run }
    let strip: AutomationEvaluationStripData
    let groups: [AutomationEvaluationGroup]
    let missing: [Double]
    let last: TimedRun?
    let lastWould: TimedRun?
    let wouldCount: Int
    let firedCount: Int
    let sentCount: Int
    let unreadableCount: Int
    var verdict: String? {
        guard let run = last?.run else { return nil }
        if run.outcome == "error" { return "error" }
        if run.outcome == "skipped", run.reason == "condition-false" { return "false" }
        if run.outcome == "skipped", run.reason == "condition-unknown" { return "unknown" }
        return "true"
    }
    func count(_ filter: AutomationEvaluationFilter) -> Int { groups.filter { filter.matches($0.kind) }.reduce(0) { $0 + $1.count } }

    init(runs: [AutomationDiagnostics.Run], trigger: AutomationTrigger, now: Double, startOfDay: Double, expectMissing: Bool) {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        let parsed: [TimedRun] = runs.compactMap { run in
            guard let date = fractional.date(from: run.t) ?? standard.date(from: run.t), date.timeIntervalSince1970 * 1000 <= now,
                  ["fired", "clamped", "dry_run", "skipped", "error"].contains(run.outcome) else { return nil }
            return TimedRun(at: (date.timeIntervalSince1970 * 1000).rounded(), run: run)
        }.sorted { $0.at < $1.at }
        unreadableCount = runs.count - parsed.count
        let today = parsed.filter { $0.at >= startOfDay }
        missing = expectMissing ? Self.missingTicks(parsed, trigger: trigger, from: startOfDay, now: now) : []
        groups = Self.group(today, missing: missing)
        strip = Self.makeStrip(parsed, trigger: trigger, now: now, expectMissing: expectMissing)
        last = parsed.last; lastWould = today.last { $0.run.outcome == "dry_run" }
        wouldCount = today.filter { $0.run.outcome == "dry_run" }.count
        firedCount = today.filter { ["fired", "clamped"].contains($0.run.outcome) }.count
        sentCount = today.filter { $0.run.sent }.count
    }
    /// Infer only absent tick evaluations after the first recorded row, allowing 45 seconds of drift.
    private static func missingTicks(_ runs: [TimedRun], trigger: AutomationTrigger, from start: Double, now: Double) -> [Double] {
        guard trigger.kind == .tick, !runs.isEmpty else { return [] }
        let step = Double(max(1, trigger.everyMin ?? 1)) * 60_000
        let times = runs.map(\.at) + [now]
        var result: [Double] = []
        for (first, next) in zip(times, times.dropFirst()) where next - first > step + 45_000 {
            // Skip directly to the visible window, even if an old controller supplied distant rows.
            var candidate = first + max(1, ceil((start - first) / step)) * step
            while candidate < next - 45_000 + 1 && candidate <= now {
                result.append(candidate); candidate += step
            }
        }
        return result
    }
    private static func makeStrip(_ runs: [TimedRun], trigger: AutomationTrigger, now: Double, expectMissing: Bool) -> AutomationEvaluationStripData {
        let end = floor(now / 60_000) * 60_000 + 60_000, start = end - 180 * 60_000
        var ticks = Array(repeating: AutomationEvaluationKind.none, count: 180)
        func paint(_ at: Double, _ kind: AutomationEvaluationKind) {
            let index = Int(floor((at - start) / 60_000))
            if ticks.indices.contains(index), kind.rank > ticks[index].rank { ticks[index] = kind }
        }
        for row in runs { paint(row.at, .from(row.run)) }
        if expectMissing { for at in missingTicks(runs, trigger: trigger, from: start, now: now) { paint(at, .missing) } }
        let gap = trigger.kind == .tick ? max(1, trigger.everyMin ?? 1) : 1
        var cooldowns: [[Int]] = [], open: [Int]?
        for index in ticks.indices {
            if ticks[index] == .cooldown {
                if let span = open, index - span[1] <= gap { open = [span[0], index] }
                else { if let open { cooldowns.append(open) }; open = [index, index] }
            } else if ticks[index] != .none, let span = open { cooldowns.append(span); open = nil }
        }
        if let open { cooldowns.append(open) }
        return .init(startMs: start, endMs: end, ticks: ticks, cooldowns: cooldowns)
    }
    /// Adjacent identical outcomes share a row; grouping never invents historical signal values.
    private static func group(_ runs: [TimedRun], missing: [Double]) -> [AutomationEvaluationGroup] {
        struct Event { let at: Double; let kind: AutomationEvaluationKind; let reason: String?; let sent: Bool; let ordinal: Int }
        let actual = runs.enumerated().map { Event(at: $0.element.at, kind: .from($0.element.run), reason: $0.element.run.reason, sent: $0.element.run.sent, ordinal: $0.offset) }
        let inferred = missing.enumerated().map { Event(at: $0.element, kind: .missing, reason: nil, sent: false, ordinal: runs.count + $0.offset) }
        let events = (actual + inferred).sorted { $0.at == $1.at ? $0.ordinal < $1.ordinal : $0.at > $1.at }
        var result: [AutomationEvaluationGroup] = []
        for event in events {
            if var last = result.last, last.kind == event.kind, last.reason == event.reason {
                last.count += 1; last.firstMs = event.at; if event.sent { last.sent += 1 }; result[result.count - 1] = last
            } else { result.append(.init(kind: event.kind, reason: event.reason, count: 1, firstMs: event.at, lastMs: event.at, sent: event.sent ? 1 : 0)) }
        }
        return result
    }
}

struct AutomationLiveThreshold: Equatable, Sendable {
    let signal: String
    let operation: String
    let value: Double
    let function: String?
    let minutes: Int?
    static func collect(_ condition: AutomationCondition) -> [Self] {
        switch condition {
        case .all(let children), .any(let children): children.flatMap(collect)
        case .not(let child): collect(child)
        case .compare(let operation, let left, .literal(let value)):
            switch left {
            case .signal(let signal): [.init(signal: signal, operation: operation, value: value, function: nil, minutes: nil)]
            case .window(let function, let signal, let minutes): [.init(signal: signal, operation: operation, value: value, function: function, minutes: minutes)]
            default: []
            }
        default: []
        }
    }
}
