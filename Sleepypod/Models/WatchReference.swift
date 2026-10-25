import Foundation

struct WatchReferenceData: Sendable {
    var heartRate: [WatchComparison.Reading] = []
    var breathing: [WatchComparison.Reading] = []
    var hrv: [WatchComparison.Reading] = []
    var stages: [WatchComparison.StageSample] = []
    var extendedMetrics = false
    var count: Int { heartRate.count + breathing.count + hrv.count + stages.count }
    func readings(_ metric: BiometricMetric) -> [WatchComparison.Reading] {
        switch metric {
        case .heartRate: heartRate
        case .hrv: hrv
        case .breathingRate: breathing
        }
    }
    func comparison(epochs: [SleepAnalyzer.SleepEpoch], vitals: [VitalsRecord]) -> WatchComparison {
        .build(
            epochs: epochs, vitals: vitals, watchStages: stages, watchHeartRate: heartRate, watchHRV: hrv,
            watchBreathing: breathing)
    }
    var csv: String {
        var rows = ["source,metric,start,end,value,unit"]
        for metric in BiometricMetric.allCases {
            let name = metric == .hrv ? "hrv_sdnn" : metric == .heartRate ? "heart_rate" : "breathing_rate"
            rows += readings(metric).map {
                "apple_watch,\(name),\($0.date.ISO8601Format()),,\(SleepCSV.number($0.value)),\(metric.unit)"
            }
        }
        rows += stages.map {
            "apple_watch,sleep_stage,\($0.start.ISO8601Format()),\($0.end.ISO8601Format()),\($0.stage.rawValue),"
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}

enum WatchImportPeriod: Int, CaseIterable, Identifiable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90
    var id: Int { rawValue }
    var title: String { "Last \(rawValue) days" }
}

struct WatchImportResult: Decodable, Sendable {
    let stages: Int
    let vitals: Int
    let breathing: Int?
    let hrv: Int?
    let rejectedStageBatches: Int
    let matchedStages: Int
    let matchedVitals: Int
    let matchedBreathing: Int?
    let matchedHrv: Int?
}

enum WatchExportFile {
    static let maximumBytes: Int64 = 512 * 1024 * 1024
    static func validate(_ url: URL) throws -> Int64 {
        guard url.isFileURL, ["zip", "xml"].contains(url.pathExtension.lowercased()) else {
            throw APIError.serverError(message: "Choose an Apple Health ZIP export or export.xml.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0, size <= maximumBytes
        else {
            throw APIError.serverError(message: "Choose a nonempty Health export no larger than 512 MiB.")
        }
        return size
    }
}

struct ReferenceHeartRate: Decodable, Identifiable, Sendable {
    let id: Int
    let side: String
    let source: String
    let timestamp: String
    let heartRate: Double
    var reading: WatchComparison.Reading? {
        guard heartRate.isFinite, let date = ReferenceDate.parse(timestamp) else { return nil }
        return .init(date: date, value: heartRate)
    }
}
struct ReferenceMetricSample: Decodable, Identifiable, Sendable {
    let timestamp: String
    let value: Double
    var id: String { timestamp }
    var reading: WatchComparison.Reading? {
        guard value.isFinite, let date = ReferenceDate.parse(timestamp) else { return nil }
        return .init(date: date, value: value)
    }
}
struct ReferenceStage: Decodable, Identifiable, Sendable {
    let id: Int
    let side: String
    let source: String
    let start: String
    let end: String
    let stage: String
    var sample: WatchComparison.StageSample? {
        guard let start = ReferenceDate.parse(start), let end = ReferenceDate.parse(end), end > start else {
            return nil
        }
        let parsedStage: SleepAnalyzer.SleepStage
        switch stage.lowercased() {
        case "wake": parsedStage = .wake
        case "light": parsedStage = .light
        case "deep": parsedStage = .deep
        case "rem": parsedStage = .rem
        default: return nil
        }
        return .init(start: start, end: end, stage: parsedStage)
    }
}
enum ReferenceDate {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
