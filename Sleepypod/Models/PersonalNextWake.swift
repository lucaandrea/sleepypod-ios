import Foundation

/// A read-only effective occurrence, bound to the same person and physical routing as the bed snapshot.
struct PersonalNextWake: Codable, Equatable, Sendable {
    let version: Int
    let scope: PersonalControlScope
    let sourceSide: Side
    let observedAt: Int64
    let plan: NextAlarmState
    let effect: String

    func validate(for bed: PersonalBed, now: Date) throws {
        try scope.validate()
        let age = now.timeIntervalSince1970 * 1_000 - Double(observedAt)
        guard version == 1, effect == "read_only", !plan.canChange, scope == bed.scope,
              bed.availability == "ready", bed.routing.routines == sourceSide,
              bed.routing.scheduledVibration == [sourceSide], PersonalControlRequest.validInstant(observedAt),
              age >= 0, age < 15_000 else { throw HouseholdFailure.conflict }
        try plan.validate(side: sourceSide)
    }
}

@MainActor enum BedRemoteWakeSummary {
    static func occurrence(_ plan: NextAlarmState, now: Date = .now) -> BedRemoteWake? {
        guard plan.state == "scheduled", plan.execution == nil, let alarm = plan.alarm,
              let at = NextAlarmState.instant(alarm.at) else { return nil }
        let wake = BedRemoteWake(side: plan.side.rawValue, at: at, timeZone: plan.timeZone,
            warmingAt: plan.warming.flatMap { NextAlarmState.instant($0.startsAt) }, targetF: plan.warming?.targetF,
            vibrationSeconds: alarm.duration)
        return wake.valid(checkedAt: now) ? wake : nil
    }
    static func text(_ plan: NextAlarmState) -> String {
        let summary = NativeActionSession.alarmSummary(plan)
        guard plan.state == "scheduled", plan.execution == nil, let alarm = plan.alarm else { return summary }
        if !plan.reason.isEmpty { return summary + " " + plan.reason }
        let vibration = " Vibration: \(alarm.duration.formatted(.number.precision(.fractionLength(0)))) seconds."
        guard let warming = plan.warming else { return summary + vibration }
        return summary + " Warming starts \(plan.label(warming.startsAt)) toward \(Int(warming.targetF))°F." + vibration
    }
}
