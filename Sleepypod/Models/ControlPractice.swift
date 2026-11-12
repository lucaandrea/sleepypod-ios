import Foundation

/// Disposable examples shared by the owner and personal entry points. Never issues a command or saves state.
struct ControlPractice: Equatable {
    enum Lesson: String, CaseIterable, Identifiable {
        case temperature, wake, stop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .temperature: "Temperature"
            case .wake: "Tomorrow’s alarm"
            case .stop: "Stop an action"
            }
        }
        var symbol: String {
            switch self {
            case .temperature: "thermometer.medium"
            case .wake: "alarm"
            case .stop: "stop.circle"
            }
        }
    }
    enum Action {
        case lesson(Lesson), step(Int), editWake(String), reviewWake, saveWake, stopTemperature, stopVibration, reset
    }
    private(set) var lesson = Lesson.temperature
    private(set) var requestedTargetF = 76
    private(set) var temperatureTried = false
    private(set) var draftWake = "08:00"
    private(set) var savedWake = "07:00"
    private(set) var reviewedWake: String?
    private(set) var wakeTried = false
    private(set) var temperatureOn = true
    private(set) var vibrationOn = true
    var completedCount: Int { Lesson.allCases.filter { completed($0) }.count }
    func completed(_ lesson: Lesson) -> Bool {
        switch lesson {
        case .temperature: temperatureTried
        case .wake: wakeTried && draftWake == savedWake
        case .stop: !temperatureOn && !vibrationOn
        }
    }
    static func validTime(_ value: String) -> Bool {
        value.utf8.count == 5 && value.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }
    /// Arithmetic keeps the illustrative warming lead independent of the phone's timezone and DST.
    static func warmingTime(_ wake: String) -> String? {
        guard validTime(wake), let hours = Int(wake.prefix(2)), let minutes = Int(wake.suffix(2)) else { return nil }
        let warming = (hours * 60 + minutes - 30 + 1440) % 1440
        return String(format: "%02d:%02d", warming / 60, warming % 60)
    }
    mutating func send(_ action: Action) {
        switch action {
        case .lesson(let lesson): self.lesson = lesson
        case .step(let degrees):
            guard degrees == -1 || degrees == 1 else { return }
            requestedTargetF = max(65, min(90, requestedTargetF + degrees))
            temperatureTried = temperatureTried || requestedTargetF != 76
        case .editWake(let time): draftWake = time; reviewedWake = nil
        case .reviewWake: reviewedWake = Self.validTime(draftWake) ? draftWake : nil
        case .saveWake:
            guard reviewedWake == draftWake, Self.validTime(draftWake) else { return }
            savedWake = draftWake; wakeTried = wakeTried || draftWake != "07:00"; reviewedWake = nil
        case .stopTemperature: temperatureOn = false
        case .stopVibration: vibrationOn = false
        case .reset: self = Self()
        }
    }
}
