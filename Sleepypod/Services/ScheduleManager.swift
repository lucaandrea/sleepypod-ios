import Foundation
import Observation

@MainActor
@Observable
final class ScheduleManager {
    var schedules: Schedules?
    var selectedDay: DayOfWeek = .monday
    var selectedDays: Set<DayOfWeek> = [.monday]
    var selectedSide: SideSelection = .left
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var revision = 0
    var error: String?

    private var api: SleepypodProtocol
    private var generation = 0
    private var readRevision = 0

    init(api: SleepypodProtocol) {
        self.api = api
    }

    func switchBackend(_ client: SleepypodProtocol) {
        generation += 1; readRevision += 1; api = client
        schedules = nil; error = nil; isLoading = false; isSaving = false
    }

    // MARK: - Current Schedule

    var currentDailySchedule: DailySchedule? {
        guard let schedules else { return nil }
        let sideSchedule = schedules.schedule(for: selectedSide.primarySide)
        return sideSchedule[selectedDay]
    }

    var phases: [SchedulePhase] {
        guard let daily = currentDailySchedule else { return [] }
        let window = CurveTimeWindow(bedtime: daily.power.on, wake: daily.power.off)
        let sorted = daily.temperatures.sorted { window.offset($0.key) < window.offset($1.key) }

        return sorted.enumerated().map { index, entry in
            let (name, icon) = Self.phaseLabel(index: index, count: sorted.count)
            return SchedulePhase(name: name, icon: icon, time: entry.key, temperatureF: entry.value)
        }
    }

    /// First point is bedtime, the last is pre-wake, and the ones between are the night holds.
    static func phaseLabel(index: Int, count: Int) -> (String, String) {
        if index == 0 { return ("Bedtime", "bed.double") }
        if index == count - 1 && count >= 2 { return ("Pre-wake", "sunrise") }
        switch index {
        case 1: return ("Deep", "moon")
        case 2: return ("Late night", "moon.stars")
        default: return ("Phase \(index + 1)", "moon.stars")
        }
    }

    func applyTemplate(_ template: CurveTemplate) async -> Bool {
        guard var updated = schedules else { return false }
        for side in selectedSide.sides {
            var sideSchedule = updated.schedule(for: side)
            for day in selectedDays {
                var daily = sideSchedule[day]
                daily.temperatures = template.points
                daily.power.on = template.bedtime
                daily.power.off = template.wake
                daily.power.enabled = true
                if APIBackend.current == .freeSleep {
                    daily.alarm.time = template.wake
                    daily.alarm.enabled = true
                }
                sideSchedule[day] = daily
            }
            updated.setSchedule(sideSchedule, for: side)
        }
        return await persist(updated, days: selectedDays)
    }

    func editPhase(oldTime: String, newTime: String, temperature: Int) async -> Bool {
        guard var updated = schedules else { return false }
        for side in selectedSide.sides {
            var sideSchedule = updated.schedule(for: side)
            for day in selectedDays {
                var daily = sideSchedule[day]
                if oldTime != newTime && daily.temperatures[newTime] != nil {
                    error = "There is already a set point at that time."
                    return false
                }
                daily.temperatures.removeValue(forKey: oldTime)
                daily.temperatures[newTime] = max(55, min(110, temperature))
                sideSchedule[day] = daily
            }
            updated.setSchedule(sideSchedule, for: side)
        }
        return await persist(updated, days: selectedDays)
    }

    // MARK: - Fetch

    func fetchSchedules(preservingError: Bool = false) async {
        guard !isSaving else { return }
        let operation = generation, client = api
        readRevision += 1; let request = readRevision
        isLoading = true
        if !preservingError { error = nil }
        defer { if operation == generation && request == readRevision { isLoading = false } }
        do {
            let received = try await client.getSchedules()
            guard operation == generation, request == readRevision, !Task.isCancelled else { return }
            schedules = received; revision += 1
        } catch {
            if operation == generation && request == readRevision { self.error = error.localizedDescription }
        }
    }

    /// Serialize saves and ignore old-controller replies; recovery reads never repeat a write.
    private func persist(_ desired: Schedules, days: Set<DayOfWeek>) async -> Bool {
        guard !isSaving else { return false }
        let operation = generation, client = api
        readRevision += 1; isLoading = false; isSaving = true; error = nil
        defer { if operation == generation { isSaving = false } }
        do {
            let received = try await client.updateSchedules(desired, days: days)
            guard operation == generation, !Task.isCancelled else { return false }
            schedules = received; revision += 1
            return true
        } catch {
            guard operation == generation else { return false }
            self.error = error.localizedDescription
            if let received = try? await client.getSchedules(), operation == generation { schedules = received; revision += 1 }
            return false
        }
    }

    // MARK: - Toggle Power Schedule

    /// What the pod does when the schedule ends: turn off, or keep the final temperature.
    func setPowerEndAction(_ action: ScheduleEndAction) async {
        guard var schedules else { return }
        let side = selectedSide.primarySide
        var sideSchedule = schedules.schedule(for: side)
        var daily = sideSchedule[selectedDay]
        guard daily.power.endAction != action else { return }

        daily.power.endAction = action
        sideSchedule[selectedDay] = daily
        schedules.setSchedule(sideSchedule, for: side)

        if selectedSide == .both {
            let other: Side = side == .left ? .right : .left
            var otherSide = schedules.schedule(for: other)
            var otherDaily = otherSide[selectedDay]
            otherDaily.power.endAction = action
            otherSide[selectedDay] = otherDaily
            schedules.setSchedule(otherSide, for: other)
        }

        _ = await persist(schedules, days: [selectedDay])
    }

    func togglePowerSchedule() async {
        guard var schedules else { return }
        let side = selectedSide.primarySide
        var sideSchedule = schedules.schedule(for: side)
        var daily = sideSchedule[selectedDay]

        daily.power.enabled.toggle()
        sideSchedule[selectedDay] = daily
        schedules.setSchedule(sideSchedule, for: side)

        if selectedSide == .both {
            var otherSide = schedules.schedule(for: side == .left ? .right : .left)
            var otherDaily = otherSide[selectedDay]
            otherDaily.power.enabled = daily.power.enabled
            otherSide[selectedDay] = otherDaily
            schedules.setSchedule(otherSide, for: side == .left ? .right : .left)
        }

        _ = await persist(schedules, days: [selectedDay])
    }

    // MARK: - Update Alarm Time

    func updateAlarmTime(_ time: String) async {
        guard var schedules else { return }
        let side = selectedSide.primarySide
        var sideSchedule = schedules.schedule(for: side)
        var daily = sideSchedule[selectedDay]
        daily.alarm.time = time
        daily.alarm.enabled = true
        sideSchedule[selectedDay] = daily
        schedules.setSchedule(sideSchedule, for: side)

        if selectedSide == .both {
            var other = schedules.schedule(for: side == .left ? .right : .left)
            var otherDaily = other[selectedDay]
            otherDaily.alarm.time = time
            otherDaily.alarm.enabled = true
            other[selectedDay] = otherDaily
            schedules.setSchedule(other, for: side == .left ? .right : .left)
        }

        _ = await persist(schedules, days: [selectedDay])
    }

    // MARK: - Update Bedtime

    func updateBedtime(_ time: String) async {
        guard var schedules else { return }
        let side = selectedSide.primarySide
        var sideSchedule = schedules.schedule(for: side)
        var daily = sideSchedule[selectedDay]
        daily.power.on = time
        daily.power.enabled = true
        sideSchedule[selectedDay] = daily
        schedules.setSchedule(sideSchedule, for: side)

        if selectedSide == .both {
            var other = schedules.schedule(for: side == .left ? .right : .left)
            var otherDaily = other[selectedDay]
            otherDaily.power.on = time
            otherDaily.power.enabled = true
            other[selectedDay] = otherDaily
            schedules.setSchedule(other, for: side == .left ? .right : .left)
        }

        _ = await persist(schedules, days: [selectedDay])
    }

    // MARK: - Update Temperature

    func updatePhaseTemperature(time: String, delta: Int) async {
        guard var schedules else { return }
        let side = selectedSide.primarySide
        var sideSchedule = schedules.schedule(for: side)
        var daily = sideSchedule[selectedDay]

        guard let currentTemp = daily.temperatures[time] else { return }
        let newTemp = max(TemperatureConversion.minTempF, min(TemperatureConversion.maxTempF, currentTemp + delta * 2))
        daily.temperatures[time] = newTemp
        sideSchedule[selectedDay] = daily
        schedules.setSchedule(sideSchedule, for: side)

        // Apply to both sides if linked
        if selectedSide == .both {
            var otherSide = schedules.schedule(for: side == .left ? .right : .left)
            var otherDaily = otherSide[selectedDay]
            otherDaily.temperatures[time] = newTemp
            otherSide[selectedDay] = otherDaily
            schedules.setSchedule(otherSide, for: side == .left ? .right : .left)
        }

        _ = await persist(schedules, days: [selectedDay])
    }

    // MARK: - Update Power Schedule

    func updatePowerSchedule(_ power: PowerSchedule) async {
        guard var schedules else { return }
        let side = selectedSide.primarySide

        for day in selectedDays {
            var sideSchedule = schedules.schedule(for: side)
            var daily = sideSchedule[day]
            daily.power = power
            sideSchedule[day] = daily
            schedules.setSchedule(sideSchedule, for: side)

            if selectedSide == .both {
                var other = schedules.schedule(for: side == .left ? .right : .left)
                var otherDaily = other[day]
                otherDaily.power = power
                other[day] = otherDaily
                schedules.setSchedule(other, for: side == .left ? .right : .left)
            }
        }

        _ = await persist(schedules, days: selectedDays)
    }

    // MARK: - Update Alarm Schedule

    func updateAlarmSchedule(_ alarm: AlarmSchedule) async {
        guard var schedules else { return }
        let side = selectedSide.primarySide

        for day in selectedDays {
            var sideSchedule = schedules.schedule(for: side)
            var daily = sideSchedule[day]
            daily.alarm = alarm
            sideSchedule[day] = daily
            schedules.setSchedule(sideSchedule, for: side)

            if selectedSide == .both {
                var other = schedules.schedule(for: side == .left ? .right : .left)
                var otherDaily = other[day]
                otherDaily.alarm = alarm
                other[day] = otherDaily
                schedules.setSchedule(other, for: side == .left ? .right : .left)
            }
        }

        _ = await persist(schedules, days: selectedDays)
    }

    // MARK: - Profile Presets

    func applyProfile(_ profile: SleepProfile) async {
        guard var updated = schedules else { return }
        for side in selectedSide.sides {
            var sideSchedule = updated.schedule(for: side)
            for day in selectedDays {
                var daily = sideSchedule[day]
                let window = CurveTimeWindow(bedtime: daily.power.on, wake: daily.power.off)
                let times = daily.temperatures.keys.sorted { window.offset($0) < window.offset($1) }
                let temperatures = profile.temperatures(for: times.count)
                for (index, time) in times.enumerated() { daily.temperatures[time] = temperatures[index] }
                sideSchedule[day] = daily
            }
            updated.setSchedule(sideSchedule, for: side)
        }
        _ = await persist(updated, days: selectedDays)
    }

}

// MARK: - Sleep Profiles

enum SleepProfile: String, CaseIterable, Identifiable, Sendable {
    case cool = "Cool"
    case balanced = "Balanced"
    case warm = "Warm"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .cool: return "Extra cool all night"
        case .balanced: return "Science-backed curve"
        case .warm: return "Warmer temperatures"
        }
    }

    func temperatures(for count: Int) -> [Int] {
        switch self {
        case .cool:
            switch count {
            case 4: return [72, 66, 66, 70]
            case 3: return [72, 66, 70]
            default: return Array(repeating: 68, count: count)
            }
        case .balanced:
            switch count {
            case 4: return [78, 74, 74, 78]
            case 3: return [78, 74, 78]
            default: return Array(repeating: 76, count: count)
            }
        case .warm:
            switch count {
            case 4: return [84, 80, 80, 84]
            case 3: return [84, 80, 84]
            default: return Array(repeating: 82, count: count)
            }
        }
    }
}
