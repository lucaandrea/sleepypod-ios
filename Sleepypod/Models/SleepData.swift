import Foundation

/// Calendar boundaries follow the Pod, including 23- and 25-hour days.
enum SleepCalendar {
    static let nightRolloverHour = 6
    static func calendar(timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        calendar.firstWeekday = 2
        return calendar
    }
    static func nightDate(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        return calendar.component(.hour, from: date) < nightRolloverHour
            ? calendar.date(byAdding: .day, value: -1, to: day) ?? day : day
    }
    static func previousNight(now: Date = .now, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
    }
    static func nightWindow(from firstDay: Date, until nextDay: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.date(bySettingHour: nightRolloverHour, minute: 0, second: 0, of: firstDay) ?? firstDay
        let end = calendar.date(bySettingHour: nightRolloverHour, minute: 0, second: 0, of: nextDay) ?? nextDay
        return DateInterval(start: start, end: max(start, end))
    }
    /// Keep every selected sleep record's morning readings, even when it ends after the next night's 6 am boundary.
    static func exportWindow(nights: DateInterval, records: [SleepRecord], now: Date = .now) -> DateInterval {
        let lastWake = records.map { $0.completedAt ?? now }.max() ?? nights.end
        return DateInterval(start: nights.start, end: max(nights.end, lastWake))
    }
}

struct SleepRecordDraft: Identifiable, Sendable {
    let original: SleepRecord
    var id: Int { original.id }
    var bedtime: Date
    var wake: Date
    var hasWake: Bool
    init(_ record: SleepRecord) {
        original = record
        bedtime = record.enteredBedDate
        wake = record.completedAt ?? .now
        hasWake = record.completedAt != nil
    }
    var validation: String? {
        if !bedtime.timeIntervalSince1970.isFinite || !wake.timeIntervalSince1970.isFinite {
            return "Choose valid bed and wake times."
        }
        if hasWake && wake <= bedtime { return "Wake time must be after bedtime." }
        if !hasWake { return "This session is still open. Add a wake time to correct its times." }
        return nil
    }
}

/// Missing measurements stay empty; CSV text is escaped independently of its origin.
enum SleepCSV {
    static func cell(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.first.map { "=+@-".contains($0) } == true ? "'" + value : value
        return safe.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\"" : safe
    }
    static func number(_ value: Double?) -> String { value.flatMap { $0.isFinite ? String($0) : nil } ?? "" }
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    static func vitals(_ records: [VitalsRecord]) -> String {
        table(
            [
                "id", "side", "timestamp", "heartRate", "hrv", "breathingRate", "interpretation", "processing_run_id",
                "provenance_status", "configuration_hash", "hrv_metric_id"
            ],
            records.map {
                [
                    String($0.id), $0.side, $0.date.ISO8601Format(), number($0.heartRate), number($0.hrv),
                    number($0.breathingRate),
                    "original_observation", $0.provenance?.processingRunId ?? $0.processingRunId ?? "",
                    $0.provenance?.status ?? ($0.processingRunId == nil ? "legacy_unknown" : "unavailable"),
                    $0.provenance?.configurationHash ?? "", $0.hrvMetricID ?? "unknown"
                ]
            })
    }
    static func sleep(_ records: [SleepRecord]) -> String {
        table(
            ["id", "side", "enteredBed", "leftBed", "durationSeconds", "timesExited"],
            records.map {
                [
                    String($0.id), $0.side, $0.enteredBedDate.ISO8601Format(), $0.completedAt?.ISO8601Format() ?? "",
                    String($0.sleepPeriodSeconds), String($0.timesExitedBed)
                ]
            })
    }
    static func movement(_ records: [MovementRecord]) -> String {
        table(
            ["id", "side", "timestamp", "totalMovement"],
            records.map {
                [String($0.id), $0.side, $0.date.ISO8601Format(), String($0.totalMovement)]
            })
    }
}

/// Split saturated date windows rather than silently accepting the API's row limit.
enum MetricRangeLoader {
    static func load<Record: Identifiable & Sendable>(
        start: Date, end: Date, limit: Int,
        fetch: @Sendable (Date, Date) async throws -> [Record]
    ) async throws -> [Record] where Record.ID: Sendable {
        try Task.checkCancellation()
        let rows = try await fetch(start, end)
        guard rows.count >= limit else { return rows }
        guard end.timeIntervalSince(start) > 1 else {
            throw APIError.serverError(
                message: "Too many readings share one timestamp. This range could not be loaded completely.")
        }
        let middle = Date(timeIntervalSince1970: floor((start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2))
        guard middle > start && middle < end else {
            throw APIError.serverError(message: "This interval could not be split safely.")
        }
        let older = try await load(start: start, end: middle, limit: limit, fetch: fetch)
        let newer = try await load(start: middle, end: end, limit: limit, fetch: fetch)
        var seen = Set<Record.ID>()
        return (newer + older).filter { seen.insert($0.id).inserted }
    }
}

struct RawSensorFile: Codable, Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let sizeBytes: Int64
    let modifiedAt: String
    var date: Date? {
        ISO8601DateFormatter().date(from: modifiedAt) ?? DateParsers.iso8601Fractional.date(from: modifiedAt)
    }
    var size: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    static func validName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_.-]+\.RAW$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
private enum DateParsers {
    static var iso8601Fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
struct RawDiskUsage: Codable, Sendable {
    let totalBytes: Int64
    let usedBytes: Int64
    let availableBytes: Int64
    let rawFileCount: Int
    let rawBytes: Int64
}
