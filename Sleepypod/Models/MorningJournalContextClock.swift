import Foundation

enum MorningJournalContextClock {
    static func wallTime(_ milliseconds: Double, timeZone: String) -> String {
        formatter(timeZone).string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
    static func floatingDate(_ value: String) -> Date? {
        guard value.count == 16, let result = formatter("GMT").date(from: value),
              formatter("GMT").string(from: result) == value else { return nil }
        return result
    }
    /// Match the displayed clock against nearby offsets; gaps stay invalid and folds retain both choices.
    static func candidates(_ value: String, timeZone: String) -> [Double] {
        guard let guess = floatingDate(value), let zone = TimeZone(identifier: timeZone) else { return [] }
        let offsets = Set(stride(from: -36, through: 36, by: 6).map {
            zone.secondsFromGMT(for: guess.addingTimeInterval(Double($0) * 3600))
        })
        return offsets.map { (guess.timeIntervalSince1970 - Double($0)) * 1000 }
            .filter { wallTime($0, timeZone: timeZone) == value }.sorted()
    }
    private static func formatter(_ timeZone: String) -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX"); value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        value.dateFormat = "yyyy-MM-dd'T'HH:mm"; value.isLenient = false
        return value
    }
}
