import Foundation

enum CalibrationKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case piezo, capacitance, temperature
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .piezo: "Heart rate and breathing"
        case .capacitance: "Presence and position"
        case .temperature: "Bed surface temperature"
        }
    }
}

/// Optional baseline fields vary by sensor and Pod generation. Unsupported fields stay unknown.
struct CalibrationParameters: Decodable, Sendable {
    struct Channel: Decodable, Sendable { let mean: Double?; let std: Double? }
    let noiseRange: Double?
    let presenceThreshold: Double?
    let format: String?
    let channels: [String: Channel]?
    let reference: Channel?
    let threshold: Double?
    let ambientMean: Double?
    let offsets: [String: Double]?
    private enum CodingKeys: String, CodingKey {
        case noiseRange = "baseline_mean_range", presenceThreshold = "presence_threshold"
        case format, channels, reference = "ref", threshold, ambientMean = "ambient_mean", offsets
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        noiseRange = try? fields.decode(Double.self, forKey: .noiseRange)
        presenceThreshold = try? fields.decode(Double.self, forKey: .presenceThreshold)
        format = try? fields.decode(String.self, forKey: .format)
        channels = try? fields.decode([String: Channel].self, forKey: .channels)
        reference = try? fields.decode(Channel.self, forKey: .reference)
        threshold = try? fields.decode(Double.self, forKey: .threshold)
        ambientMean = try? fields.decode(Double.self, forKey: .ambientMean)
        offsets = try? fields.decode([String: Double].self, forKey: .offsets)
    }
    var piezo: (noise: Double, threshold: Double)? {
        guard let noiseRange, let presenceThreshold, noiseRange.isFinite, noiseRange >= 0,
              presenceThreshold.isFinite, presenceThreshold > 0 else { return nil }
        return (noiseRange, presenceThreshold)
    }
    var capacitance: CalibrationCapBaseline? {
        guard format == "capSense2", let channels, let threshold, threshold.isFinite else { return nil }
        var means: [Double] = [], deviations: [Double] = []
        for key in ["A", "B", "C"] {
            guard let mean = channels[key]?.mean, let deviation = channels[key]?.std,
                  mean.isFinite, deviation.isFinite, deviation >= 0 else { return nil }
            means.append(mean); deviations.append(deviation)
        }
        let reference = reference?.mean ?? 1.16
        guard reference.isFinite else { return nil }
        return .init(means: means, deviations: deviations, threshold: threshold, reference: reference)
    }
    func temperatureMeans(side: Side) -> [String: Double] {
        guard let ambientMean, ambientMean.isFinite, let offsets else { return [:] }
        let scale = abs(ambientMean) >= 100 ? 100.0 : 1
        return Dictionary(uniqueKeysWithValues: ["outer", "center", "inner"].compactMap { zone in
            guard let offset = offsets["\(side.rawValue)_\(zone)_temp"], offset.isFinite else { return nil }
            return (zone, (ambientMean + offset) / scale)
        })
    }
}

struct CalibrationCapBaseline: Sendable {
    let means: [Double]
    let deviations: [Double]
    let threshold: Double
    let reference: Double
    var band: Double { 3 * sqrt(deviations.reduce(0) { $0 + $1 * $1 }) }
    // Compensate each paired channel for reference drift, matching Core's occupancy baseline.
    func deviation(_ values: [Double]) -> [Double]? {
        guard values.count >= 6, values.prefix(6).allSatisfy({ $0.isFinite && $0 != -1 }) else { return nil }
        let referenceDelta = values.count >= 8 && values[6...7].allSatisfy({ $0.isFinite && $0 != -1 })
            ? (values[6] + values[7]) / 2 - reference : 0
        return (0..<3).map { index -> Double in
            let firstChannel = values[index * 2]
            let secondChannel = values[index * 2 + 1]
            let pairedMean = (firstChannel + secondChannel) / 2.0
            return pairedMean - referenceDelta - means[index]
        }
    }
    func channelsInBaseline(_ values: [Double]) -> Int? {
        deviation(values).map { values in values.enumerated().filter { abs($0.element) <= 3 * deviations[$0.offset] }.count }
    }
}

struct SensorCalibrationProfile: Decodable, Sendable {
    let id: Int
    let side: String
    let sensorType: String
    let status: String
    let qualityScore: Double?
    let samplesUsed: Int?
    let createdAt: String?
    let expiresAt: String?
    let errorMessage: String?
    let parameters: CalibrationParameters?
    var active: Bool { ["pending", "running"].contains(status) }
    var created: Date? { Self.date(createdAt) }
    var expires: Date? { Self.date(expiresAt) }
    var identity: String { "\(id):\(createdAt ?? "unknown")" }
    func validity(at now: Date) -> (remaining: Double, seconds: Double)? {
        guard let created, let expires, expires > created else { return nil }
        let seconds = expires.timeIntervalSince(now)
        return (min(1, max(0, seconds / expires.timeIntervalSince(created))), seconds)
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static var formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct SensorCalibrationStatus: Decodable, Sendable {
    let piezo: SensorCalibrationProfile?
    let capacitance: SensorCalibrationProfile?
    let temperature: SensorCalibrationProfile?
    subscript(_ kind: CalibrationKind) -> SensorCalibrationProfile? {
        switch kind {
        case .piezo: piezo
        case .capacitance: capacitance
        case .temperature: temperature
        }
    }
    var active: Bool { CalibrationKind.allCases.contains { self[$0]?.active == true } }
}
