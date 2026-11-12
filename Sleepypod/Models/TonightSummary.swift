import Foundation

enum TonightSummary {
    /// A solo sleeper can keep independent schedules on both physical zones.
    static func planSide(selected: Side, settings: PodSettings?) -> Side {
        guard let settings, settings.unusedZoneMode != "independent" else { return selected }
        return settings.contextSide(selected: selected)
    }
    static func isMorning(now: Date, timeZone: String) -> Bool {
        guard let zone = TimeZone(identifier: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return (4..<13).contains(calendar.component(.hour, from: now))
    }
    static func mode(_ status: PersonalComfortStatus?, now: Date) -> String {
        guard let status, status.generatedAt.isFinite else { return "Not checked" }
        let generated = Date(timeIntervalSince1970: status.generatedAt / 1000)
        guard generated <= now.addingTimeInterval(60), now.timeIntervalSince(generated) <= 90 else { return "Not checked" }
        switch status.state?.config.mode {
        case "off", nil: return "Off"
        case "preview": return "Preview · no adjustments"
        case "active":
            guard status.activation.current == true else { return "Activation not confirmed" }
            guard status.fault == nil, status.runtime == "running" else { return "Unavailable · check Autopilot" }
            if (status.state?.pausedUntil ?? 0) > now.timeIntervalSince1970 * 1000 { return "Paused after manual control" }
            return "Active · bounded adjustments"
        default: return "Not checked"
        }
    }
    static func nextWake(_ page: NextAlarmState?, now: Date) -> String {
        guard let page else { return "Not checked" }
        if page.state == "away" { return "Paused while away" }
        if page.state == "skipped" { return "Next occurrence skipped" }
        guard let alarm = page.alarm else { return "No alarm scheduled" }
        guard let at = NextAlarmState.instant(alarm.at), at > now else { return "Alarm time passed · refresh to confirm" }
        return "\(clock(at, timeZone: page.timeZone)) · \(alarm.duration.formatted())s vibration"
    }
    static func warming(alarm: NextAlarmState?, limit: ComfortLimitPage?, now: Date) -> String {
        guard let alarm, alarm.state == "scheduled", let next = alarm.alarm, let at = NextAlarmState.instant(next.at), at > now else {
            return "Review your wake plan before relying on it."
        }
        guard let wake = limit?.wake, abs(wake.alarmAt / 1000 - at.timeIntervalSince1970) < 0.001,
              wake.targetF == next.alarmTemperatureF, wake.timeZone == alarm.timeZone else {
            return "Warming not confirmed · refresh the plan."
        }
        return "Warming from \(clock(wake.startsDate, timeZone: wake.timeZone)) toward \(wake.targetF.formatted())°F."
    }
    private static func clock(_ date: Date, timeZone: String) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.setLocalizedDateFormatFromTemplate("EEEjm")
        return formatter.string(from: date)
    }
}
