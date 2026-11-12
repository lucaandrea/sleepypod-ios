import Foundation

/// Matches the controller's immutable, bounded comparison plan. Dates are local night dates; clocks are UTC milliseconds.
enum ComfortExperimentContract {
    static func require(_ condition: Bool) throws { if !condition { throw HouseholdFailure.invalid } }
    static func identifier(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    static func hash(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    static func instant(_ value: Int64) -> Bool { (0...253_402_300_799_000).contains(value) }
    static func temperature(_ value: Int) -> Bool { (55...110).contains(value) }
    static func date(_ value: String) -> Bool { MorningJournalDates.valid(value) }
    static func shifted(_ value: String, days: Int) -> String {
        guard let start = ISO8601DateFormatter().date(from: value + "T12:00:00Z") else { return "" }
        return MorningJournalDates.key(start.addingTimeInterval(Double(days) * 86_400), timeZone: "GMT")
    }
    static func localDate(_ value: Int64, zone: String) -> String {
        MorningJournalDates.key(Date(timeIntervalSince1970: Double(value) / 1000), timeZone: zone)
    }
    static func now(_ value: Date) -> Int64 { Int64(value.timeIntervalSince1970 * 1000) }
}

struct ComfortExperimentContext: Codable, Equatable, Sendable {
    let subjectKey: String
    let bindingHash: String
    let routineHash: String
    let wakeHash: String
    let timezone: String
    let baselineF: Int
    let minimumF: Int
    let maximumF: Int
    func validate() throws {
        try ComfortExperimentContract.require([subjectKey, bindingHash, routineHash, wakeHash].allSatisfy(ComfortExperimentContract.hash)
            && timezone.utf16.count <= 100 && TimeZone(identifier: timezone) != nil
            && [baselineF, minimumF, maximumF].allSatisfy(ComfortExperimentContract.temperature)
            && minimumF <= baselineF && baselineF <= maximumF)
    }
}

struct ComfortExperimentWindow: Codable, Equatable, Sendable {
    struct Wake: Codable, Equatable, Sendable {
        let at: Int64
        let startsAt: Int64
        let temperatureF: Double
        let vibrationSeconds: Int
        let source: String
    }
    let date: String
    let powerScheduleId: Int
    let windowStart: Int64
    let windowEnd: Int64
    let routineEnd: Int64
    let endAction: String
    let wake: Wake?
    func validate() throws {
        try ComfortExperimentContract.require(ComfortExperimentContract.date(date) && powerScheduleId > 0
            && [windowStart, windowEnd, routineEnd].allSatisfy(ComfortExperimentContract.instant)
            && windowEnd - windowStart >= 4 * 3_600_000 && routineEnd >= windowEnd
            && routineEnd - windowStart <= 26 * 3_600_000 && ["turn_off", "maintain"].contains(endAction))
        if let wake {
            try ComfortExperimentContract.require(wake.startsAt == windowEnd && wake.at >= wake.startsAt
                && ComfortExperimentContract.instant(wake.at) && (55...110).contains(wake.temperatureF)
                && (0...180).contains(wake.vibrationSeconds) && ["routine", "override"].contains(wake.source))
        }
    }
}

struct ComfortExperimentSchedule: Codable, Equatable, Sendable {
    struct Skipped: Codable, Equatable, Sendable { let date: String; let reason: String }
    let requestedFirstNightDate: String
    let windows: [ComfortExperimentWindow]
    let skipped: [Skipped]
    func validate() throws {
        try ComfortExperimentContract.require(ComfortExperimentContract.date(requestedFirstNightDate)
            && windows.count == 16 && skipped.count <= 63)
        for window in windows { try window.validate() }
        let reasons = ["not_scheduled", "already_started", "unbounded_routine", "overlapping_routines",
                       "wake_overlap", "conflicting_alarms", "too_short", "needs_following_night"]
        try ComfortExperimentContract.require(skipped.allSatisfy { ComfortExperimentContract.date($0.date) && reasons.contains($0.reason) })
    }
}

struct ComfortExperimentNight: Codable, Equatable, Sendable, Identifiable {
    let date: String
    let pair: Int
    let period: Int
    let role: String
    let arm: String
    let targetF: Int
    var id: String { date }
}

struct ComfortExperimentPlan: Codable, Equatable, Sendable, Identifiable {
    let version: Int
    let id: String
    let createdAt: Int64
    let context: ComfortExperimentContext
    let firstNightDate: String
    let variantF: Int
    let orders: [String]
    let schedule: ComfortExperimentSchedule?
    func validate() throws {
        try context.validate()
        try ComfortExperimentContract.require([1, 2].contains(version) && ComfortExperimentContract.identifier(id)
            && ComfortExperimentContract.instant(createdAt) && ComfortExperimentContract.date(firstNightDate)
            && (1...2).contains(abs(variantF - context.baselineF)) && (context.minimumF...context.maximumF).contains(variantF)
            && orders.count == 4 && orders.filter { $0 == "baseline_first" }.count == 2
            && orders.filter { $0 == "variant_first" }.count == 2 && (version == 2) == (schedule != nil))
        let earliest = ComfortExperimentContract.localDate(createdAt, zone: context.timezone)
        try ComfortExperimentContract.require(firstNightDate >= earliest && firstNightDate <= ComfortExperimentContract.shifted(earliest, days: 30))
        guard let schedule else { return }
        try schedule.validate()
        let windows = schedule.windows, requested = schedule.requestedFirstNightDate
        let dates = (windows.map(\.date) + schedule.skipped.map(\.date)).sorted()
        try ComfortExperimentContract.require(requested >= earliest && requested <= firstNightDate && windows[0].date == firstNightDate
            && windows[15].date < ComfortExperimentContract.shifted(requested, days: 63)
            && dates.first == requested && dates.last == windows[15].date)
        for index in dates.indices where index > 0 {
            try ComfortExperimentContract.require(dates[index] == ComfortExperimentContract.shifted(dates[index - 1], days: 1))
        }
        for (index, window) in windows.enumerated() {
            try ComfortExperimentContract.require(window.windowStart >= createdAt
                && ComfortExperimentContract.localDate(window.windowStart, zone: context.timezone) == window.date)
            if index > 0 {
                try ComfortExperimentContract.require(window.date > windows[index - 1].date && window.windowStart >= windows[index - 1].routineEnd)
                if index % 2 == 1 { try ComfortExperimentContract.require(window.date == ComfortExperimentContract.shifted(windows[index - 1].date, days: 1)) }
            }
        }
    }
    var nights: [ComfortExperimentNight] {
        guard orders.count == 4, version == 1 || schedule?.windows.count == 16 else { return [] }
        return (0..<16).map { index in
            let pair = index / 4, period = index % 4 / 2
            let baseline = (orders[pair] == "baseline_first") == (period == 0)
            return .init(date: schedule?.windows[index].date ?? ComfortExperimentContract.shifted(firstNightDate, days: index),
                pair: pair, period: period, role: index % 2 == 0 ? "settling" : "scored", arm: baseline ? "baseline" : "variant",
                targetF: baseline ? context.baselineF : variantF)
        }
    }
}

struct ComfortExperimentFeedback: Codable, Equatable, Sendable {
    let nightDate: String
    let confirmedFullNight: Bool
    let comfort: Int
    let unwantedAdjustments: Int
    let problem: Bool
    func validate() throws {
        try ComfortExperimentContract.require(ComfortExperimentContract.date(nightDate) && (0...10).contains(comfort)
            && (0...100_000).contains(unwantedAdjustments))
    }
}

struct ComfortExperimentRecord: Decodable, Equatable, Sendable {
    struct Feedback: Decodable, Equatable, Sendable {
        let nightDate: String
        let recordedAt: Int64
        let confirmedFullNight: Bool
        let comfort: Int
        let unwantedAdjustments: Int
        let problem: Bool
        var value: ComfortExperimentFeedback { .init(nightDate: nightDate, confirmedFullNight: confirmedFullNight, comfort: comfort, unwantedAdjustments: unwantedAdjustments, problem: problem) }
    }
    let plan: ComfortExperimentPlan
    let revision: String
    let updatedAt: Int64
    let status: String
    let stoppedAt: Int64?
    let feedback: [Feedback]
    let exposures: [ComfortExperimentExposure]
    func validate(generatedAt: Int64) throws {
        try plan.validate()
        try ComfortExperimentContract.require(ComfortExperimentContract.identifier(revision) && updatedAt >= plan.createdAt && updatedAt <= generatedAt
            && ["planned", "stopped"].contains(status) && (status == "stopped") == (stoppedAt != nil)
            && (stoppedAt.map { $0 >= plan.createdAt && $0 <= updatedAt } ?? true))
        try ComfortExperimentContract.require(feedback.count <= 16 && Set(feedback.map(\.nightDate)).count == feedback.count)
        try ComfortExperimentContract.require(exposures.count <= 16 && Set(exposures.map(\.nightDate)).count == exposures.count)
        for exposure in exposures { try exposure.validate(updatedAt: updatedAt) }
        for item in feedback {
            try item.value.validate()
            try ComfortExperimentContract.require(ComfortExperimentContract.instant(item.recordedAt) && item.recordedAt <= updatedAt
                && plan.nights.contains { $0.date == item.nightDate })
        }
    }
}
