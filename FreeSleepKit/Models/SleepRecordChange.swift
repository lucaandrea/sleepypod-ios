import Foundation

struct SleepRecordIdentity: Codable, Sendable {
    struct Window: Codable, Sendable {
        var entered_bed_at: String
        var left_bed_at: String
    }
    var side: BedSide
    var expected: Window
    init(side: BedSide, episode: SleepAnalytics.Night) {
        self.side = side
        expected = .init(entered_bed_at: episode.startedAt, left_bed_at: episode.endedAt)
    }
}

struct SleepRecordChange: Encodable, Sendable {
    var side: BedSide
    var expected: SleepRecordIdentity.Window
    var entered_bed_at: String
    var left_bed_at: String
    static func valid(start: Date, end: Date) -> Bool {
        let from = floor(start.timeIntervalSince1970); let until = floor(end.timeIntervalSince1970)
        return from.isFinite && until.isFinite && from >= -2147483648 && until <= 2147483647
            && until > from && until - from <= 72 * 60 * 60
    }
    init(identity: SleepRecordIdentity, start: Date, end: Date) throws {
        guard Self.valid(start: start, end: end) else { throw PodError.message("Choose an end after the start, within a 72-hour window.") }
        side = identity.side; expected = identity.expected
        entered_bed_at = Self.iso(start); left_bed_at = Self.iso(end)
    }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)))
    }
}
