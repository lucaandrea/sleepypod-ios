import Foundation

struct PersonalComfortConfig: Codable, Equatable, Sendable {
    var mode: String
    var minimumF: Int
    var maximumF: Int
    var sensorAware: Bool?
    var followBedtime: Bool?
    var editable: Self { var value = self; if value.mode != "preview" { value.mode = "off" }; return value }
    func validate() throws {
        guard ["off", "preview"].contains(mode), (55...110).contains(minimumF), (55...110).contains(maximumF), minimumF <= maximumF,
              followBedtime != true || sensorAware == true else {
            throw APIError.serverError(message: "Use Off or Preview, a 55–110°F range, and the Pod sensor guard for bed-entry timing.")
        }
    }
}
struct PersonalComfortStatus: Codable, Sendable {
    struct State: Codable, Sendable {
        let config: PersonalComfortConfig
        let offsetF: Int
        let feedbackThrough: String
        let learnedSession: String
        let pausedUntil: Double
        let lastAppliedAt: Double
        let lastTargetF: Double?
        let lastSegment: String
    }
    struct Decision: Codable, Sendable {
        let eligible: Bool
        let baselineF: Double?
        let proposedF: Double?
        let reason: String
        let retainPreviousLease: Bool
        let pauseRequired: Bool
    }
    struct Activation: Codable, Sendable { let available: Bool; let reason: String; var current: Bool? }
    struct Features: Codable, Sendable { let sensorAware: Bool; let followBedtime: Bool; let nightReports: Bool?; var modeOnly: Bool?; var ownerActivation: Bool? }
    let apiVersion: Int
    let generatedAt: Double
    let side: Side
    let timezone: String?
    let deviceDate: String?
    let state: State?
    let evaluatedAt: Double?
    let decision: Decision?
    let fault: String?
    let history: [PersonalComfortEvent]
    let runtime: String
    let activation: Activation
    let features: Features
    let signals: PersonalComfortSignals?
    let timing: PersonalComfortTiming?

    var ownerActive: Bool { state?.config.mode == "active" && activation.current == true }
    var modeTitle: String {
        if ownerActive { return "Personal comfort active" }
        switch state?.config.mode {
        case "preview": return "Preview only"
        case "active": return "Activation not confirmed"
        default: return "Personal comfort off"
        }
    }
    var modeExplanation: String {
        if ownerActive { return "Owner activation is current. Every adjustment rechecks live sensor, routine and safety guards." }
        if state?.config.mode == "active" { return "A saved Active mode alone does not authorize adjustments. Refresh or review the current owner qualification." }
        return "Preview does not adjust the bed. Your routines and rules continue."
    }

    func validate(side expected: Side) throws {
        guard apiVersion == 1, side == expected, !activation.available, generatedAt.isFinite,
              ["running", "stopped"].contains(runtime), timezone.flatMap(TimeZone.init(identifier:)) != nil || timezone == nil else {
            throw APIError.serverError(message: "The controller returned an unsupported personal-comfort response. Refresh before making changes.")
        }
        if let deviceDate, PersonalComfortDates.date(deviceDate) == nil { throw APIError.serverError(message: "The controller's local date is unavailable.") }
    }
}
struct PersonalComfortSignals: Codable, Sendable {
    let state: String
    let reason: String
    let sampleAt: Double?
    let expiresAt: Double?
    let baselineHeartRate: Double?
    let baselineDays: Int
    let baselineWindows: Int
    let baselineAsOf: Double?
    let recentHeartRates: [Double]
    let sourceSide: Side?
    let source: String
}
struct PersonalComfortTiming: Codable, Sendable {
    struct Selection: Codable, Sendable {
        let session: String
        let revision: String
        let sourceKey: String
        let entryAt: Double
        let confirmedAt: Double
        let shiftMinutes: Int
    }
    let state: String
    let reason: String
    let selection: Selection?
    let scheduledBaselineF: Double?
    let phaseBaselineF: Double?
}
struct PersonalComfortEvent: Codable, Sendable {
    let at: Double
    let kind: String
    let session: String?
    let message: String
    let proposedF: Double?
    let reportedF: Double?
    let eligible: Bool
    let deviceObservedAt: Double?
    let presenceObservedAt: Double?
    let owner: String?
    let signals: PersonalComfortSignals?
    let timing: PersonalComfortTiming?
}
struct PersonalComfortFeedback: Codable, Equatable, Sendable {
    var date: String
    var comfort: String
    func validate(deviceDate: String?) throws {
        guard ["warm", "cold", "comfortable"].contains(comfort), let deviceDate,
              PersonalComfortDates.feedbackDates(through: deviceDate).contains(date) else {
            throw APIError.serverError(message: "Choose the controller's current date or one of the previous fourteen dates.")
        }
    }
}

enum PersonalComfortDates {
    private static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else { return nil }; return parsed
    }
    /// These are Pod-local calendar labels, not dates in the phone's timezone.
    static func feedbackDates(through value: String) -> [String] {
        guard let end = date(value) else { return [] }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return (0...14).compactMap { calendar.date(byAdding: .day, value: -$0, to: end).map(formatter.string) }
    }
    static func clock(_ value: Double?, timezone: String?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        let formatter = DateFormatter(); formatter.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
    }
    static func duration(_ milliseconds: Double) -> String { DisplayTime.duration(Int(max(0, milliseconds / 1000))) }
}
