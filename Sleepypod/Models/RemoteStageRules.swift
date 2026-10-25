import Foundation

enum RemoteSleepStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case wake, light, deep, rem
    var id: String { rawValue }
    var title: String { self == .rem ? "REM" : rawValue.capitalized }
}
enum RemoteStageMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case hrRatio, heartRate, hrv, breathingRate, movement
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hrRatio: "HR ratio"
        case .heartRate: "Heart rate"
        case .hrv: "HRV"
        case .breathingRate: "Breathing"
        case .movement: "Movement"
        }
    }
    var unit: String {
        switch self {
        case .heartRate: "bpm"
        case .hrv: "ms"
        case .breathingRate: "br/min"
        default: ""
        }
    }
}
enum RemoteStageOperator: String, Codable, CaseIterable, Identifiable, Sendable {
    case less = "<"
    case atMost = "<="
    case greater = ">"
    case atLeast = ">="
    var id: String { rawValue }
    var title: String {
        switch self {
        case .atMost: "≤"
        case .atLeast: "≥"
        default: rawValue
        }
    }
}
struct RemoteStageCondition: Codable, Equatable, Identifiable, Sendable {
    let id = UUID()
    var metric: RemoteStageMetric
    var op: RemoteStageOperator
    var value: Double
    enum CodingKeys: CodingKey { case metric, op, value }
    static func == (left: Self, right: Self) -> Bool {
        left.metric == right.metric && left.op == right.op && left.value == right.value
    }
    var summary: String {
        "\(metric.title) \(op.title) \(value.formatted(.number.precision(.fractionLength(0...3))))\(metric.unit.isEmpty ? "" : " " + metric.unit)"
    }
}
struct RemoteStageRule: Codable, Equatable, Identifiable, Sendable {
    let id = UUID()
    var stage: RemoteSleepStage
    var when: [RemoteStageCondition]
    enum CodingKeys: CodingKey { case stage, when }
    static func == (left: Self, right: Self) -> Bool { left.stage == right.stage && left.when == right.when }
    var summary: String {
        "\(stage.title) when \(when.isEmpty ? "always" : when.map(\.summary).joined(separator: " and "))"
    }
}
struct RemoteStageTransition: Codable, Equatable, Identifiable, Sendable {
    let id = UUID()
    var from: RemoteSleepStage
    var to: RemoteSleepStage
    var via: RemoteSleepStage
    enum CodingKeys: CodingKey { case from, to, via }
    static func == (left: Self, right: Self) -> Bool {
        left.from == right.from && left.to == right.to && left.via == right.via
    }
}
struct RemoteStageRange: Codable, Equatable, Sendable {
    var min: Double
    var max: Double
}
struct RemoteStageRuleset: Codable, Equatable, Sendable {
    struct Outliers: Codable, Equatable, Sendable {
        var heartRate: RemoteStageRange
        var hrv: RemoteStageRange
        var breathingRate: RemoteStageRange
        var heartRateSpikeStdDevs: Double
    }
    var outliers: Outliers
    var lowSignalBelow: Double
    var lowSignalRules: [RemoteStageRule]
    var rules: [RemoteStageRule]
    var fallback: RemoteSleepStage
    var smoothIsolatedEpochs: Bool
    var transitions: [RemoteStageTransition]
    var validation: String? {
        guard rules.count <= 32, lowSignalRules.count <= 32, transitions.count <= 16 else {
            return "Use at most 32 rules per list and 16 transitions."
        }
        for rule in rules + lowSignalRules {
            guard rule.when.count <= 8, rule.when.allSatisfy({ $0.value.isFinite }) else {
                return "Each rule can have up to eight conditions with finite values."
            }
        }
        for range in [outliers.heartRate, outliers.hrv, outliers.breathingRate] {
            guard range.min.isFinite && range.max.isFinite && range.min <= range.max else {
                return "Each signal minimum must be no greater than its maximum."
            }
        }
        guard lowSignalBelow.isFinite && (0...1).contains(lowSignalBelow) else {
            return "Low-signal quality must be between 0 and 1."
        }
        guard outliers.heartRateSpikeStdDevs.isFinite && (0...10).contains(outliers.heartRateSpikeStdDevs) else {
            return "The spike threshold must be between 0 and 10 standard deviations."
        }
        return nil
    }
    func quickCondition(stage: RemoteSleepStage, metric: RemoteStageMetric) -> (rule: Int, condition: Int)? {
        for (index, rule) in rules.enumerated() where rule.stage == stage {
            if let condition = rule.when.firstIndex(where: { $0.metric == metric }) { return (index, condition) }
        }
        return nil
    }
}
struct RemoteStageClassifier: Codable, Equatable, Sendable {
    var engine = "rules"
    var ruleset: RemoteStageRuleset
    var validation: String? {
        engine == "rules" ? ruleset.validation : "This classification engine is not supported by this editor."
    }
}
struct RemoteStageState: Decodable, Sendable {
    struct Pending: Decodable, Sendable {
        let classifier: RemoteStageClassifier
        let generation: Int
        let warning: String?
    }
    struct Provenance: Decodable, Sendable {
        let source: String
        let generation: Int?
        let warning: String?
        let stageHash: String?
    }
    struct Preset: Decodable, Identifiable, Sendable {
        let id: String
        let label: String
        let description: String
        let classifier: RemoteStageClassifier
    }
    struct Change: Decodable, Identifiable, Sendable {
        let id: Int
        let changedAt: Double
        let summary: String
        let before: RemoteStageClassifier?
        let agreementBefore: Double?
        let agreementAfter: Double?
    }
    var classifier: RemoteStageClassifier
    var isDefault: Bool
    var pending: Pending?
    var provenance: Provenance?
    var defaults: RemoteStageClassifier
    var presets: [Preset]
    var changes: [Change]
    var desired: RemoteStageClassifier { pending?.classifier ?? classifier }
}
struct RemoteStagePreview: Decodable, Sendable {
    struct Summary: Decodable, Sendable {
        struct Agreement: Decodable, Sendable {
            let accuracy: Double
            let kappa: Double?
            let epochs: Int?
            let recall: [String: Double?]?
            let confusion: [String: [String: Double]]?
        }
        struct RuleStats: Decodable, Sendable {
            let epochs: Int
            let hits: [Int]
            let matches: [Int]
            let shadowedBy: [Int?]
            let fallbackHits: Int
        }
        struct Stats: Decodable, Sendable {
            let lowSignalNights: Int
            let rules: RuleStats?
            let lowSignalRules: RuleStats?
            let metricRanges: [String: RemoteStageRange?]
            let heartRateReadings: Int
            let spikesDropped: Int
            let smoothed: Int
            let transitionFixes: Int
        }
        let distribution: [String: Double]
        let durations: [String: Double]
        let qualityScore: Double
        let agreement: Agreement?
        let stats: Stats?
        let blocks: [PodSleepStages.Block]?
    }
    struct Changed: Decodable, Sendable {
        struct Segment: Decodable, Sendable {
            let start: Double
            let end: Double
        }
        let segments: [Segment]
        let changed: Int
        let total: Int
    }
    let nights: Int
    let hasReference: Bool
    let saved: Summary?
    let candidate: Summary?
    let changed: Changed?
    let enteredBedAt: Double?
    let leftBedAt: Double?
}
