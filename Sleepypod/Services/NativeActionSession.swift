import Foundation
import FreeSleepKit
import Observation

/// Shared by cold-launch App Intents and the native command-history screen.
@MainActor @Observable final class NativeActionSession {
    let historyExample: Bool
    private let controls: Result<NativeControlService, Error>
    private let personal: @MainActor () throws -> any NativePersonalActionClient
    private let alarms: @MainActor () throws -> any NextAlarmClient
    private let comfort: @MainActor () throws -> any PersonalComfortClient
    private let owner: @MainActor () -> [String]
    private let live: @MainActor () -> Bool
    var bridge: NativePodActionBridge { .init { [self] in try await perform($0) } }

    init(historyExample: Bool = false, controls: Result<NativeControlService, Error>,
         personal: @escaping @MainActor () throws -> any NativePersonalActionClient,
         alarms: @escaping @MainActor () throws -> any NextAlarmClient,
         comfort: @escaping @MainActor () throws -> any PersonalComfortClient,
         owner: @escaping @MainActor () -> [String] = { OwnerConnection.revision },
         live: @escaping @MainActor () -> Bool = { APIBackend.current == .sleepypodCore }) {
        self.historyExample = historyExample; self.controls = controls; self.personal = personal; self.alarms = alarms; self.comfort = comfort
        self.owner = owner; self.live = live
    }
    static func configured() -> NativeActionSession {
        var example = false
        #if DEBUG
        example = APIBackend.current.isDemo && DebugRoute.commandHistoryScenario != "normal"
        #endif
        let controls = Result {
            #if DEBUG
            if example { return try NativeCommandExample.service(scenario: DebugRoute.commandHistoryScenario) }
            #endif
            return try NativeControlService(ledger: .persistent(), client: { try CoreNativeControlClient(transport: .configured()) })
        }
        return .init(historyExample: example, controls: controls, personal: { try CoreNativePersonalActionClient(transport: .configured()) },
                     alarms: { try CoreNextAlarmClient(transport: .configured()) }, comfort: { try CorePersonalComfortClient(transport: .configured()) })
    }
    func history() throws -> [NativeControlAttempt] { try controls.get().history() }
    func refresh(_ id: UUID) async throws { _ = try await controls.get().refresh(id) }
    func review(_ id: UUID) throws { try controls.get().review(id) }

    func perform(_ action: NativePodAction) async throws -> NativePodActionReply {
        let scope = owner(); try check(scope)
        let result: NativePodActionReply
        if let command = try Self.command(action) {
            let attempt = try await controls.get().submit(command)
            guard let receipt = attempt.receipt else {
                throw APIError.serverError(message: "This command's result is unknown. Open Settings → Command history to check it. It has not been resent.")
            }
            guard receipt.state == "acknowledged" else { throw APIError.serverError(message: receipt.message) }
            result = .message(receipt.message)
        } else { result = try await settingsAction(action, scope: scope) }
        try check(scope); return result
    }
    /// Map explicit user actions to the accepted strict Core action contract, without rounding intent input.
    static func command(_ action: NativePodAction) throws -> NativeControlAction? {
        let command: NativeControlAction
        switch action {
        case .temperature(let value, let temperature):
            guard temperature.isFinite, temperature.rounded() == temperature, (55...110).contains(temperature) else {
                throw APIError.serverError(message: "Choose a whole temperature from 55 to 110°F.")
            }
            command = .init(kind: "temperature", side: try side(value), temperature: Int(temperature))
        case .power(let value, let enabled): command = .init(kind: "power", side: try side(value), powered: enabled)
        case .position(let head, let feet): command = .init(kind: "base.position", head: head, feet: feet, feedRate: 50)
        case .preset(let preset):
            let positions = ["flat": (0, 0), "sleep": (1, 5), "relax": (30, 15), "read": (40, 0)]
            guard let position = positions[preset] else { throw NativeControlFailure.invalid }
            command = .init(kind: "base.position", head: position.0, feet: position.1, feedRate: 50)
        case .stopBase: command = .init(kind: "base.stop")
        case .dismissAlarm(let value): command = .init(kind: "vibration.clear", side: try side(value))
        default: return nil
        }
        try command.validate(); return command
    }
    private func settingsAction(_ action: NativePodAction, scope: [String]) async throws -> NativePodActionReply {
        switch action {
        case .readTemperature(let value, let current):
            return .number(try await personal().temperature(side: Self.side(value), current: current))
        case .away(let value, let enabled):
            let side = try Self.side(value)
            try await personal().away(side: side, enabled: enabled)
            return .message("Away mode is saved as \(enabled ? "on" : "off") for the \(side.rawValue) side.")
        case .prime:
            try await personal().prime()
            return .message("The controller accepted the priming request. Check Water & priming in the app for progress.")
        case .comfort(let value, let mode): return try await setComfort(side: Self.side(value), mode: mode, scope: scope)
        case .nextAlarm(let value):
            let client = try alarms(); try await client.available(); try check(scope)
            let side = try Self.side(value), result = try await client.read(side: side)
            try result.validate(side: side); return .message(Self.alarmSummary(result))
        case .changeAlarm(let value, let action, let time): return try await changeAlarm(side: Self.side(value), action: action, time: time, scope: scope)
        case .summary, .syncHealth: throw APIError.serverError(message: "Open the app to use your personal Health integration.")
        default: throw NativeControlFailure.invalid
        }
    }
    private func setComfort(side: Side, mode: String, scope: [String]) async throws -> NativePodActionReply {
        guard ["off", "preview"].contains(mode) else { throw APIError.serverError(message: "Active comfort adjustments are not available. Choose Off or Preview.") }
        let client = try comfort(); let before = try await client.status(side: side)
        try before.validate(side: side); try check(scope)
        guard before.features.modeOnly == true else { throw APIError.serverError(message: "Update the controller to change comfort mode while preserving its saved limits.") }
        let result = try await client.mode(side: side, mode: mode)
        try result.validate(side: side)
        guard result.state?.config.mode == mode else { throw NativeControlFailure.invalid }
        return .message("Personal comfort \(mode == "off" ? "Off" : "Preview") is saved for the \(side.rawValue) side. Preview does not adjust the bed.")
    }
    private func changeAlarm(side: Side, action: String, time: String?, scope: [String]) async throws -> NativePodActionReply {
        let client = try alarms(); try await client.available(); try check(scope)
        let before = try await client.read(side: side); try check(scope)
        let input = try NextAlarmWrite(base: before, action: action, time: time)
        let result: NextAlarmState
        do { result = try await client.write(input) }
        catch {
            throw APIError.serverError(message: "The alarm change could not be confirmed. Open Next alarm to refresh and review the saved occurrence before trying again. The request was not repeated.")
        }
        try result.validate(side: side, write: true)
        return .message(Self.alarmSummary(result) + (result.schedulerUpdated == false
            ? " Timer registration is pending; delivery has not been confirmed." : " Saved on the controller; physical vibration has not been verified."))
    }
    static func alarmSummary(_ value: NextAlarmState) -> String {
        let prefix = "\(value.side.displayName) side · \(value.timeZone). "
        if value.state == "away" { return prefix + "Away mode is on; this side's alarm is paused." }
        guard let alarm = value.alarm else { return prefix + "No upcoming alarm." }
        let event = value.label(alarm.at)
        let detail = value.state == "skipped" ? "Skipped once: \(event). " + (value.followingAt.map { "Following routine alarm: \(value.label($0))." } ?? "No following routine alarm.")
            : "Next alarm: \(event)."
        return prefix + detail + (value.execution.map { " Delivery state: \($0); physical vibration is unverified." } ?? "")
    }
    private static func side(_ value: String) throws -> Side {
        guard let side = Side(rawValue: value) else { throw NativeControlFailure.invalid }; return side
    }
    private func check(_ scope: [String]) throws {
        try Task.checkCancellation()
        guard live() else { throw APIError.serverError(message: "Connect to your real sleepypod controller before using this action.") }
        guard owner() == scope else { throw NativeControlFailure.changedOwner }
    }
}
