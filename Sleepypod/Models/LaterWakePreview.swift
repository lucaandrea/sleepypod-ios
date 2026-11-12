import Foundation

struct LaterWakeRequest: Codable, Equatable, Sendable {
    let side: Side
    let expectedRevision: String
    let expectedAt: String
    let time: String

    init(base: NextAlarmState, time: String) throws {
        try base.validate(side: base.side)
        guard base.canChange, base.state == "scheduled", let alarm = base.alarm,
              base.warming != nil, NextAlarmState.validClock(time) else { throw NextAlarmFailure.invalid }
        side = base.side; expectedRevision = base.revision; expectedAt = alarm.at; self.time = time
    }
}

struct LaterWakePreview: Decodable, Equatable, Sendable {
    struct Proposal: Decodable, Equatable, Sendable {
        let at: String
        let time: String
        let duration: Double
        let wakeWindow: Double
        let targetF: Double
        let warmingStartsAt: String
        let earliestVibrationAt: String
        let warmingEndsAt: String
        let changeExpiresAt: String
    }
    let apiVersion: Int
    let effect: String
    let generatedAt: String
    let expiresAt: String
    let before: NextAlarmState
    let proposed: Proposal
    let request: NextAlarmWrite
    let weeklyScheduleChanged: Bool
    let externalDevices: String

    /// Verify source, occurrence, clock and unchanged timing intervals before display.
    func validate(input: LaterWakeRequest, now: Date) throws {
        try before.validate(side: input.side)
        guard apiVersion == 1, effect == "preview_only", !weeklyScheduleChanged, externalDevices == "not_included",
              before.canChange, before.state == "scheduled", before.revision == input.expectedRevision,
              let alarm = before.alarm, alarm.at == input.expectedAt, let warming = before.warming,
              request == (try NextAlarmWrite(base: before, action: "time", time: input.time)),
              proposed.time == input.time, NextAlarmState.validClock(proposed.time),
              let generated = NextAlarmState.instant(generatedAt), let expires = NextAlarmState.instant(expiresAt),
              generated <= now, now < expires, expires > generated, expires.timeIntervalSince(generated) <= 90,
              let original = NextAlarmState.instant(alarm.at), let originalStart = NextAlarmState.instant(warming.startsAt),
              let originalEnd = NextAlarmState.instant(warming.endsAt), let originalEarliest = NextAlarmState.instant(warming.earliestVibrationAt),
              expires <= originalStart, let at = NextAlarmState.instant(proposed.at), at > original,
              NextAlarmState.clock(at, timeZone: before.timeZone) == proposed.time,
              let start = NextAlarmState.instant(proposed.warmingStartsAt), let end = NextAlarmState.instant(proposed.warmingEndsAt),
              let earliest = NextAlarmState.instant(proposed.earliestVibrationAt), let expiry = NextAlarmState.instant(proposed.changeExpiresAt),
              start.timeIntervalSince(at) == originalStart.timeIntervalSince(original),
              end.timeIntervalSince(at) == originalEnd.timeIntervalSince(original),
              earliest.timeIntervalSince(at) == originalEarliest.timeIntervalSince(original), expiry == end,
              proposed.duration == alarm.duration, proposed.wakeWindow == alarm.wakeWindow,
              proposed.targetF == alarm.alarmTemperatureF, (55...110).contains(proposed.targetF) else { throw NextAlarmFailure.invalid }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: before.timeZone) ?? .gmt
        guard calendar.isDate(original, inSameDayAs: at),
              before.followingAt.flatMap(NextAlarmState.instant).map({ at < $0 }) ?? true else { throw NextAlarmFailure.invalid }
    }

    func validateSaved(_ saved: NextAlarmState) throws {
        try saved.validate(side: before.side, write: true)
        guard saved.revision != before.revision, saved.state == "scheduled", saved.alarm?.source == "override",
              saved.alarm?.at == proposed.at, saved.alarm?.time == proposed.time,
              saved.alarm?.duration == proposed.duration, saved.alarm?.wakeWindow == proposed.wakeWindow,
              saved.alarm?.alarmTemperatureF == proposed.targetF,
              saved.warming?.startsAt == proposed.warmingStartsAt, saved.warming?.endsAt == proposed.warmingEndsAt,
              saved.warming?.earliestVibrationAt == proposed.earliestVibrationAt, saved.warming?.targetF == proposed.targetF,
              saved.change?.status == "active", saved.change?.at == proposed.at,
              saved.change?.expiresAt == proposed.changeExpiresAt else { throw NextAlarmFailure.invalid }
    }
}

/// Retain exact reviewed JSON, including required null fields. Re-encoding the
/// projection would omit nulls or future fields and change the reviewed plan.
struct LaterWakePacket: Equatable, Sendable {
    let preview: LaterWakePreview
    let input: LaterWakeRequest
    private let source: Data
    init(data: Data, input: LaterWakeRequest, now: Date) throws {
        guard data.count <= 65_536 else { throw NextAlarmFailure.invalid }
        let preview = try JSONDecoder().decode(LaterWakePreview.self, from: data)
        try preview.validate(input: input, now: now)
        self.preview = preview; self.input = input; source = data
    }
    func application(now: Date) throws -> Data {
        try preview.validate(input: input, now: now)
        return Data("{\"preview\":".utf8) + source + Data("}".utf8)
    }
}
