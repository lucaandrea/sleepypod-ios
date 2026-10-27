import Foundation

/// Place preparation and settling points next to the requested sleep window, across midnight.
struct CurveTimeWindow: Sendable {
    let start: Int
    let duration: Int
    init(bedtime: String, wake: String) {
        start = AlarmDraft.clockMinutes(bedtime) ?? 0
        let span = ((AlarmDraft.clockMinutes(wake) ?? 0) - start + 1440) % 1440
        duration = span == 0 ? 1440 : span
    }
    func offset(_ time: String) -> Int {
        let forward = ((AlarmDraft.clockMinutes(time) ?? 0) - start + 1440) % 1440
        // Outside the sleep window, choose the nearer edge instead of assuming the next day.
        if forward > duration, 1440 - forward < forward - duration { return forward - 1440 }
        return forward
    }
}

struct CurveDays: Codable, Equatable, Sendable {
    var left: [DayOfWeek] = []
    var right: [DayOfWeek] = []
    subscript(_ side: Side) -> [DayOfWeek] {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }
    var isEmpty: Bool { left.isEmpty && right.isEmpty }
    var normalized: Self {
        Self(left: DayOfWeek.weekdays.filter { left.contains($0) }, right: DayOfWeek.weekdays.filter { right.contains($0) })
    }
    static func label(_ days: [DayOfWeek]) -> String {
        let selected = Set(days)
        if selected.count == 7 { return "Every day" }
        if selected == Set(DayOfWeek.weekdays.prefix(5)) { return "Weekdays" }
        if selected == [.saturday, .sunday] { return "Weekends" }
        return DayOfWeek.weekdays.filter { selected.contains($0) }.map { String($0.displayName.prefix(3)) }.joined(separator: ", ")
    }
}

struct PodCurve: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var name: String
    var bedtime: String
    var wake: String
    var points: [String: Double]
    var notes: String
    var endAction: ScheduleEndAction?
    var days: CurveDays?
    var active: Bool?
    var ordered: [CurvePoint] { CurvePoint.ordered(points.map { CurvePoint(time: $0.key, temperature: $0.value) }) }
}

struct CurvePoint: Identifiable, Equatable, Sendable {
    var id = UUID()
    var time: String
    var temperature: Double
    var minutes: Int { AlarmDraft.clockMinutes(time) ?? 0 }
    static func clock(_ minutes: Int) -> String {
        let normalized = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }
    /// Match the web's overnight ordering: a gap longer than twelve hours separates nights.
    static func ordered(_ points: [Self]) -> [Self] {
        let sorted = points.sorted { ($0.minutes, $0.temperature) < ($1.minutes, $1.temperature) }
        guard let split = sorted.indices.dropLast().first(where: { sorted[$0 + 1].minutes - sorted[$0].minutes > 720 }) else { return sorted }
        return Array(sorted[(split + 1)...]) + Array(sorted[...split])
    }
    /// Rebase wall-clock points without using the phone's timezone or crossing a DST boundary.
    static func rebase(_ points: [Self], from start: String, until end: String, to newStart: String, until newEnd: String) -> [Self] {
        let window = CurveTimeWindow(bedtime: start, wake: end)
        let oldSpan = window.duration
        let nextStart = AlarmDraft.clockMinutes(newStart) ?? 0
        let nextSpan = ((AlarmDraft.clockMinutes(newEnd) ?? 0) - nextStart + 1440) % 1440
        return points.map { point in
            var result = point
            let offset = window.offset(point.time)
            let moved: Int
            if offset < 0 { moved = offset }
            else if offset > oldSpan { moved = nextSpan + offset - oldSpan }
            else { moved = Int((Double(offset) / Double(oldSpan) * Double(nextSpan)).rounded()) }
            result.time = clock(nextStart + moved)
            return result
        }
    }
}

struct CurveDraft: Identifiable, Sendable {
    let id = UUID()
    var original: PodCurve?
    var name = ""
    var points: [CurvePoint] = []
    var notes = ""
    var days = CurveDays()
    var active = true
    var endAction = ScheduleEndAction.turnOff
    var bedtime = "22:00"
    var wake = "07:00"
    var coolest = 68
    var warmest = 86
    var ordered: [CurvePoint] { CurvePoint.ordered(points) }
    init(curve: PodCurve? = nil, copy: Bool = false) {
        guard let curve else { return }
        original = copy ? nil : curve
        name = copy ? "\(curve.name.prefix(24)) copy" : curve.name
        points = curve.ordered; notes = curve.notes; days = copy ? CurveDays() : curve.days ?? CurveDays()
        active = copy ? false : curve.active ?? false; endAction = curve.endAction ?? .turnOff
        bedtime = ordered.first?.time ?? curve.bedtime; wake = ordered.last?.time ?? curve.wake
        coolest = Int(points.map(\.temperature).min() ?? 68); warmest = Int(points.map(\.temperature).max() ?? 86)
    }
    var validation: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 30 { return "Give this curve a name of up to 30 characters." }
        if !(2...48).contains(points.count) { return "Add between 2 and 48 set points." }
        if Set(points.map(\.time)).count != points.count { return "Each set point needs a different time." }
        if points.contains(where: { AlarmDraft.clockMinutes($0.time) == nil || !$0.temperature.isFinite || !(55...110).contains($0.temperature) }) {
            return "Use valid times and temperatures from 55°F to 110°F."
        }
        if notes.count > 1000 { return "Keep notes within 1,000 characters." }
        return nil
    }
    var payload: CurvePut {
        CurvePut(id: original?.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                 bedtime: ordered.first?.time ?? bedtime, wake: ordered.last?.time ?? wake,
                 points: Dictionary(points.map { ($0.time, $0.temperature) }, uniquingKeysWith: { _, last in last }),
                 notes: notes, endAction: endAction, days: days.normalized, active: active && !days.isEmpty)
    }
    mutating func rebase(bedtime newBedtime: String, wake newWake: String) {
        points = CurvePoint.rebase(points, from: bedtime, until: wake, to: newBedtime, until: newWake)
        bedtime = newBedtime; wake = newWake
    }
    mutating func setBounds(coolest minimum: Int, warmest maximum: Int) {
        let oldSpan = warmest - coolest
        points = points.map { point in
            var changed = point
            let fraction = oldSpan == 0 ? 0.5 : min(1, max(0, (point.temperature - Double(coolest)) / Double(oldSpan)))
            changed.temperature = (Double(minimum) + fraction * Double(maximum - minimum)).rounded()
            return changed
        }
        coolest = minimum; warmest = maximum
    }
    mutating func generate(_ intensity: CoolingIntensity) {
        let generated = ScheduleCurveAlgorithm.temperatures(bedtimeMinutes: AlarmDraft.clockMinutes(bedtime) ?? 1320,
            wakeMinutes: AlarmDraft.clockMinutes(wake) ?? 420, intensity: intensity, minimum: coolest, maximum: warmest)
        points = ScheduleCurveAlgorithm.simplify(generated.map { CurvePoint(time: $0.key, temperature: min(110, max(55, $0.value))) })
    }
}

struct CurvePut: Encodable, Sendable {
    var id: Int?
    var name: String
    var bedtime: String
    var wake: String
    var points: [String: Double]
    var notes: String
    var endAction: ScheduleEndAction
    var days: CurveDays
    var active: Bool
}
struct CurveMove: Codable, Equatable, Sendable {
    var name: String
    var side: Side
    var days: [DayOfWeek]
    var deactivated: Bool
    static func preview(_ draft: CurveDraft, among curves: [PodCurve]) -> [Self] {
        guard draft.active else { return [] }
        return curves.filter { $0.id != draft.original?.id && $0.active == true }.flatMap { other in
            let intersections = Side.allCases.map { side in other.days?[side].filter { draft.days[side].contains($0) } ?? [] }
            let leftRemaining = (other.days?.left.count ?? 0) - intersections[0].count
            let rightRemaining = (other.days?.right.count ?? 0) - intersections[1].count
            return Side.allCases.enumerated().compactMap { index, side -> CurveMove? in
                guard !intersections[index].isEmpty else { return nil }
                return Self(name: other.name, side: side, days: intersections[index], deactivated: leftRemaining + rightRemaining == 0)
            }
        }
    }
}
struct CurveChange: Decodable, Sendable { var curve: PodCurve; var moved: [CurveMove] }
struct CurveLibrarySnapshot: Sendable { var curves: [PodCurve]; var supportsAssignments: Bool }
