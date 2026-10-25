import Foundation

@MainActor
final class DemoAlarms {
    private let workspace: RoutineWorkspace?
    init(workspace: RoutineWorkspace? = nil) { self.workspace = workspace }
    private var overrides: [BedSide: AlarmPreview] = [:]
    private var replacedDates: [BedSide: Date] = [:]
    var timeZone = TimeZone(identifier: "America/Los_Angeles")!
    var away: [BedSide: Bool] = [:]

    func preview(side: BedSide, now: Date = .now) -> AlarmPreview {
        if away[side] == true { return AlarmPreview(side: side, timeZone: timeZone.identifier, state: "away") }
        if var saved = overrides[side], let expiry = saved.expiresAt.flatMap(AlarmPreview.date), expiry > now {
            saved.timeZone = timeZone.identifier
            if var occurrence = saved.alarm {
                occurrence.time = saved.format(occurrence.at, pattern: "HH:mm")
                saved.alarm = occurrence
            }
            if let occurrence = saved.alarm, let date = AlarmPreview.date(occurrence.at), date <= now {
                saved.state = "paused"; saved.alarm = nil
            }
            return saved
        }
        if let book = workspace?.demoBook {
            let alarm = RoutinePlan.nextAlarm(book, side: side, now: now, timeZone: timeZone)
            return AlarmPreview(side: side, timeZone: timeZone.identifier, state: alarm == nil ? "none" : "scheduled", alarm: alarm)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: 7, minute: 0), matchingPolicy: .nextTime)!
        return AlarmPreview(side: side, timeZone: timeZone.identifier, state: "scheduled",
            alarm: .init(at: next.ISO8601Format(), time: "07:00", scheduleDay: nil, source: "routine"), expiresAt: nil)
    }

    // Simulated state stays on this app instance and never enters the live API or device-action path.
    func change(_ request: AlarmChange, now: Date = .now) throws -> AlarmPreview {
        var current = preview(side: request.side, now: now)
        if request.action == .restore {
            guard current.expiresAt != nil, current.expiresAt == request.expectedExpiresAt,
                  current.overrideRevision == request.expectedRevision else { throw PodError.message("The alarm changed. Refresh and review it before trying again.") }
            overrides[request.side] = nil; replacedDates[request.side] = nil
            return preview(side: request.side, now: now)
        }
        guard let alarm = current.alarm, alarm.at == request.expectedAt, let date = AlarmPreview.date(alarm.at) else {
            throw PodError.message("The alarm changed. Refresh and review it before trying again.")
        }
        let replaced = alarm.source == "routine" ? date : replacedDates[request.side] ?? date
        if request.action == .disable {
            let expiry = max(date.addingTimeInterval(120), current.expiresAt.flatMap(AlarmPreview.date) ?? date)
            current.state = "paused"; current.alarm = nil; current.expiresAt = expiry.ISO8601Format()
        } else {
            guard let time = request.time else { throw PodError.message("Choose an alarm time.") }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            let components = time.split(separator: ":").compactMap { Int($0) }
            guard components.count == 2, (0...23).contains(components[0]), (0...59).contains(components[1]) else { throw PodError.message("Choose a valid alarm time.") }
            var target = calendar.dateComponents([.year, .month, .day], from: date)
            target.hour = components[0]; target.minute = components[1]; target.second = 0
            let start = calendar.startOfDay(for: date).addingTimeInterval(-1)
            let first = calendar.nextDate(after: start, matching: target, matchingPolicy: .strict, repeatedTimePolicy: .first)
            let last = calendar.nextDate(after: start, matching: target, matchingPolicy: .strict, repeatedTimePolicy: .last)
            guard let candidate = first, candidate == last else { throw PodError.message("Choose a time outside the daylight-saving transition.") }
            guard candidate > now else { throw PodError.message("Choose a future time on the displayed alarm date.") }
            current.alarm = .init(at: candidate.ISO8601Format(), time: time, scheduleDay: nil, source: "override")
            current.expiresAt = max(candidate, replaced).addingTimeInterval(120).ISO8601Format()
        }
        current.overrideRevision = UUID().uuidString.lowercased()
        overrides[request.side] = current; replacedDates[request.side] = replaced
        return current
    }
}
