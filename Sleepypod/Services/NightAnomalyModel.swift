import Foundation

/// A small learned nearest-neighbour model. Later nights calibrate its score, never its feature scaling.
struct NightAnomalyModel: Codable, Sendable, Equatable {
    static let version = "night-neighbors-v1"
    static let minimumNights = 40
    static let maximumNights = 90
    static let requiredFeatures = ["sleepMinutes", "midpointMinutes"]
    static let optionalFeatures = ["awakeFraction", "heartRate", "hrvSDNN", "respiratoryRate"]
    static let featureNames = ["sleepMinutes": "Recorded sleep", "midpointMinutes": "Sleep timing",
                               "awakeFraction": "Recorded awake time", "heartRate": "Overnight heart rate",
                               "hrvSDNN": "Watch HRV (SDNN)", "respiratoryRate": "Breathing rate"]
    private static let scaleFloors = ["sleepMinutes": 15.0, "midpointMinutes": 15.0, "awakeFraction": 0.02,
                                      "heartRate": 2.0, "hrvSDNN": 5.0, "respiratoryRate": 0.5]

    struct Assessment: Sendable, Equatable {
        let nightID: String
        let score: Double
        let referencePercentile: Double
        let unusual: Bool
        let differences: [Difference]
    }

    struct Difference: Sendable, Equatable, Identifiable {
        let feature: String
        let value: Double
        let reference: Double
        let scaledDifference: Double
        var id: String { feature }
    }

    enum Failure: LocalizedError, Equatable {
        case insufficient, invalidData, changedSource, referenceNight, staleBaseline, corruptModel
        var errorDescription: String? {
            switch self {
            case .insufficient: "Review at least 40 complete nights from the same source. Twenty later nights are reserved for score calibration."
            case .invalidData: "The selected nights contain missing, conflicting or invalid measurements. Refresh and review them again."
            case .changedSource: "The sleep source changed. This model cannot compare different devices or people."
            case .referenceNight: "This night helped build the baseline. It cannot be reported as an independent new result."
            case .staleBaseline: "The baseline is over 45 days older than this night. Refresh and review recent nights before retraining."
            case .corruptModel: "The saved model is incomplete or unsupported. Refresh the data and train a new baseline."
            }
        }
    }

    let algorithm: String
    let sourceID: String
    let sourceName: String
    let trainedAt: Date
    let referenceStart: Date
    let referenceEnd: Date
    let trainingNights: Int
    let calibrationNights: Int
    let features: [String]
    let midpointAnchor: Double
    let centers: [Double]
    let scales: [Double]
    let neighbors: [[Double]]
    let calibrationScores: [Double]
    let referenceTokens: [String: String]

    /// The fixed model choice avoids selecting a threshold or architecture using the later calibration nights.
    static func fit(_ reviewed: [NightAnomalyObservation], now: Date, includeVitals: Bool = false) throws -> Self {
        let sorted = Array(reviewed.sorted { $0.start < $1.start }.suffix(maximumNights))
        guard sorted.count >= minimumNights else { throw Failure.insufficient }
        guard let first = sorted.first, let last = sorted.last,
              Set(sorted.map(\.sourceID)).count == 1, Set(sorted.map(\.id)).count == sorted.count,
              sorted.allSatisfy({ validNight($0, now: now) }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end <= $1.start }) else { throw Failure.invalidData }
        guard now.timeIntervalSince(last.end) <= 45 * 86400 else { throw Failure.staleBaseline }
        let calibrationCount = max(20, sorted.count / 3)
        let training = Array(sorted.dropLast(calibrationCount))
        let calibration = Array(sorted.suffix(calibrationCount))
        // Choose columns on training data only. Later calibration must supply those same columns; never impute.
        let optional = includeVitals ? optionalFeatures : ["awakeFraction"]
        let features = requiredFeatures + optional.filter { feature in training.allSatisfy { $0.values[feature]?.isFinite == true } }
        if includeVitals && !features.contains(where: { ["heartRate", "hrvSDNN", "respiratoryRate"].contains($0) }) {
            throw Failure.invalidData
        }
        let anchor = circularCenter(training.compactMap { $0.values["midpointMinutes"] })
        let raw = try training.map { try vector($0, features: features, anchor: anchor) }
        let centers = features.indices.map { index in median(raw.map { $0[index] }) }
        let scales = features.indices.map { index in
            max(scaleFloors[features[index]] ?? 1, 1.4826 * median(raw.map { abs($0[index] - centers[index]) }))
        }
        let neighbors = raw.map { row in row.indices.map { (row[$0] - centers[$0]) / scales[$0] } }
        let scores = try calibration.map { night in
            let values = try vector(night, features: features, anchor: anchor)
            let normalized = values.indices.map { (values[$0] - centers[$0]) / scales[$0] }
            return distance(normalized, neighbors: neighbors)
        }.sorted()
        let model = Self(algorithm: version, sourceID: first.sourceID, sourceName: first.sourceName, trainedAt: now,
                         referenceStart: first.start, referenceEnd: last.end, trainingNights: training.count,
                         calibrationNights: calibration.count, features: features, midpointAnchor: anchor,
                         centers: centers, scales: scales, neighbors: neighbors, calibrationScores: scores,
                         referenceTokens: Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.reviewToken) }))
        try model.validate()
        return model
    }

    /// Score only genuinely later nights, keeping retrospective fitting out of the "new result" lane.
    func assess(_ night: NightAnomalyObservation, now: Date) throws -> Assessment {
        try validate()
        guard trainedAt <= now else { throw Failure.invalidData }
        guard night.sourceID == sourceID else { throw Failure.changedSource }
        guard Self.validNight(night, now: now) else { throw Failure.invalidData }
        guard night.start >= referenceEnd, referenceTokens[night.id] == nil else { throw Failure.referenceNight }
        guard now.timeIntervalSince(referenceEnd) <= 45 * 86400 else { throw Failure.staleBaseline }
        let raw = try Self.vector(night, features: features, anchor: midpointAnchor)
        let normalized = raw.indices.map { (raw[$0] - centers[$0]) / scales[$0] }
        let score = Self.distance(normalized, neighbors: neighbors)
        let rank = Double(calibrationScores.filter { $0 < score }.count) / Double(calibrationScores.count)
        // Near-identical rounded reference nights must not make trivial timing changes look unusual.
        let threshold = max(1, calibrationScores[min(calibrationScores.count - 1, Int(ceil(0.95 * Double(calibrationScores.count))) - 1)])
        guard score.isFinite else { throw Failure.invalidData }
        let differences = features.indices.map { index in
            let timing = features[index] == "midpointMinutes"
            let reference = timing ? (centers[index] + midpointAnchor + 1440).truncatingRemainder(dividingBy: 1440) : centers[index]
            return Difference(feature: features[index], value: night.values[features[index]] ?? raw[index], reference: reference, scaledDifference: normalized[index])
        }.sorted { abs($0.scaledDifference) > abs($1.scaledDifference) }
        return Assessment(nightID: night.id, score: score, referencePercentile: rank, unusual: score > threshold, differences: differences)
    }

    /// Reloading Health history invalidates a model when any of its actual source nights changed or disappeared.
    func referencesMatch(_ available: [NightAnomalyObservation]) -> Bool {
        let byID = Dictionary(available.filter { $0.sourceID == sourceID }.map { ($0.id, $0.reviewToken) }, uniquingKeysWith: { first, _ in first })
        return referenceTokens.allSatisfy { byID[$0.key] == $0.value }
    }

    func validate() throws {
        guard algorithm == Self.version, !sourceID.isEmpty, trainedAt.timeIntervalSince1970.isFinite,
              referenceEnd > referenceStart, trainedAt >= referenceEnd,
              trainingNights >= 20, calibrationNights >= 20, trainingNights + calibrationNights <= Self.maximumNights,
              referenceTokens.count == trainingNights + calibrationNights,
              features.starts(with: Self.requiredFeatures), Set(features).count == features.count,
              features.allSatisfy({ (Self.requiredFeatures + Self.optionalFeatures).contains($0) }),
              midpointAnchor.isFinite, centers.count == features.count, scales.count == features.count,
              centers.allSatisfy(\.isFinite), scales.allSatisfy({ $0.isFinite && $0 > 0 }),
              neighbors.count == trainingNights, neighbors.allSatisfy({ $0.count == features.count && $0.allSatisfy(\.isFinite) }),
              calibrationScores.count == calibrationNights, calibrationScores == calibrationScores.sorted(),
              calibrationScores.allSatisfy({ $0.isFinite && $0 >= 0 }),
              referenceTokens.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else { throw Failure.corruptModel }
    }

    private static func validNight(_ night: NightAnomalyObservation, now: Date) -> Bool {
        let duration = night.end.timeIntervalSince(night.start)
        return duration.isFinite && (6 * 3600...12 * 3600).contains(duration) && night.end <= now
            && night.coverage.isFinite && (0.9...1).contains(night.coverage)
            && night.maximumGapMinutes.isFinite && (0...30).contains(night.maximumGapMinutes) && night.sampleCount > 0
            && !night.sourceID.isEmpty && !night.reviewToken.isEmpty && night.evidenceDigest.count == 64
            && requiredFeatures.allSatisfy { night.values[$0]?.isFinite == true }
            && (360...720).contains(night.values["sleepMinutes"] ?? 0)
            && (night.values["sleepMinutes"] ?? .infinity) <= duration / 60 + 0.01
            && (0..<1440).contains(night.values["midpointMinutes"] ?? -1)
            && night.values.allSatisfy { feature, value in
                guard value.isFinite else { return false }
                switch feature {
                case "awakeFraction": return (0...1).contains(value)
                case "heartRate": return (20...250).contains(value)
                case "hrvSDNN": return (0...500).contains(value)
                case "respiratoryRate": return (3...60).contains(value)
                default: return requiredFeatures.contains(feature)
                }
            }
    }

    private static func vector(_ night: NightAnomalyObservation, features: [String], anchor: Double) throws -> [Double] {
        try features.map { feature in
            guard let value = night.values[feature], value.isFinite else { throw Failure.invalidData }
            return feature == "midpointMinutes" ? wrapped(value - anchor) : value
        }
    }

    private static func distance(_ values: [Double], neighbors: [[Double]]) -> Double {
        let distances = neighbors.map { neighbor in
            sqrt(zip(values, neighbor).reduce(0) { $0 + pow($1.0 - $1.1, 2) } / Double(values.count))
        }.sorted()
        let nearest = distances.prefix(5)
        return nearest.reduce(0, +) / Double(nearest.count)
    }

    private static func circularCenter(_ minutes: [Double]) -> Double {
        let sine = minutes.reduce(0) { $0 + sin($1 * 2 * .pi / 1440) }
        let cosine = minutes.reduce(0) { $0 + cos($1 * 2 * .pi / 1440) }
        let phase = atan2(sine, cosine) * 1440 / (2 * .pi)
        return phase < 0 ? phase + 1440 : phase
    }

    private static func wrapped(_ minutes: Double) -> Double {
        let value = (minutes + 720).truncatingRemainder(dividingBy: 1440)
        return (value < 0 ? value + 1440 : value) - 720
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
