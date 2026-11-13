import Foundation
import FreeSleepKit

/// The owner remote names physical sides explicitly; personal accounts use their server-assigned zones instead.
@MainActor final class OwnerBedRemoteSource: BedRemoteSource {
    private struct Capability: Decodable, Sendable {
        struct Observation: Decodable, Sendable { let freshness: String; let observedAt: String?; let expiresAt: String? }
        struct Observations: Decodable, Sendable { let device: Observation }
        let apiVersion: Int
        let observations: Observations
    }
    private struct Status: Decodable, Sendable {
        struct Zone: Decodable, Sendable {
            let currentTemperature: Double?
            let targetTemperature: Double?
            let heatingDuration: Int
        }
        let leftSide: Zone
        let rightSide: Zone
        let waterLevel: String
        let isPriming: Bool
        let temperatureControl: SidePair<TemperatureControlStatus>?
    }
    private struct Reviewed {
        let settings: SleeperPreferencesSnapshot
        let sides: [Side]
        let target: [Int?]
    }
    private let selected: () -> [Side]
    private let owner: () -> [String]
    private let permitted: () -> Bool
    private let transport: () throws -> CoreRESTClient
    private let makeControls: () throws -> NativeControlService
    private var controls: NativeControlService?
    private var reviewed: [UUID: Reviewed] = [:]
    var context: [String] { owner() + selected().map(\.rawValue) + [String(permitted())] }

    init(selected: @escaping () -> [Side], owner: @escaping () -> [String] = { OwnerConnection.revision },
         permitted: @escaping () -> Bool = { !PersonalWorkspaceBoundary.isActive && APIBackend.current == .sleepypodCore },
         transport: @escaping () throws -> CoreRESTClient = { try .configured() }, controls: @escaping () throws -> NativeControlService) {
        self.selected = selected; self.owner = owner; self.permitted = permitted; self.transport = transport; self.makeControls = controls
    }
    /// Protected receipt storage may be unavailable until the first phone unlock; retry on a new read.
    func prepareRead() throws {
        guard permitted() else { throw BedRemoteFailure.unavailable }
        if controls == nil { controls = try makeControls() }
    }
    func read() async throws -> BedRemoteReading {
        try prepareRead()
        guard permitted() else { throw BedRemoteFailure.unavailable }
        let expected = context, sides = selected(), client = try transport()
        guard !sides.isEmpty, sides.count <= 2, Set(sides).count == sides.count else { throw BedRemoteFailure.invalid }
        let settings: SleeperPreferencesSnapshot = try await client.get("settings")
        let capability: Capability = try await client.get("v1/capabilities")
        let status: Status = try await client.get("device/status", query: ["unit": "F"])
        let alarm = try? await CoreNextAlarmClient(transport: client).read(side: sides[0])
        guard context == expected, permitted(), settings.device.issue == nil, capability.apiVersion == 1 else { throw BedRemoteFailure.changed }
        let now = Date(), observation = capability.observations.device
        let observedAt = observation.observedAt.flatMap(NextAlarmState.instant)
        let fresh = observation.freshness == "fresh" && observation.expiresAt.flatMap(NextAlarmState.instant).map { $0 > now } == true
            && observedAt.map { $0 <= now && now.timeIntervalSince($0) < 15 } == true
        let zones: [BedRemoteSnapshot.Zone] = try sides.map { side in
            let zone = side == .left ? status.leftSide : status.rightSide
            let requested = status.temperatureControl?[side]?.targetTemperature
            guard requested.map({ $0.isFinite && (55...110).contains($0) }) ?? true else { throw BedRemoteFailure.invalid }
            return .init(id: side.rawValue, measuredF: fresh ? zone.currentTemperature : nil,
                         requestedF: requested.map { Int($0.rounded()) }, powered: fresh ? zone.heatingDuration > 0 : nil)
        }
        let canAdjust = fresh && status.waterLevel == "ok" && !status.isPriming
        let snapshot = BedRemoteSnapshot(lease: UUID(), receivedAt: now, expiresAt: now.addingTimeInterval(30),
            observationAt: fresh ? observedAt : nil, person: "Owner controls",
            assignment: sides.count == 2 ? "Both sides" : "\(sides[0].displayName) side", zones: zones,
            nextAlarm: alarm.map(BedRemoteWakeSummary.text) ?? "Next alarm unavailable. Check it on iPhone.",
            canAdjust: canAdjust, canStop: true,
            explanation: canAdjust ? "Manual temperature hold · 30 minutes" : "Refresh readings and check water or priming on iPhone.",
            wake: alarm.flatMap { BedRemoteWakeSummary.occurrence($0, now: now) })
        try snapshot.validate()
        reviewed = [snapshot.lease: .init(settings: settings, sides: sides, target: zones.map(\.requestedF))]
        return .init(context: expected, snapshot: snapshot)
    }
    func perform(_ request: BedRemoteRequest, reviewed reading: BedRemoteReading,
                 validateBeforeSubmit: @escaping @MainActor () throws -> Void) async throws -> String {
        guard let original = reviewed[reading.snapshot.lease], let controls, permitted(), context == reading.context else { throw BedRemoteFailure.changed }
        let client = try transport()
        let settings: SleeperPreferencesSnapshot = try await client.get("settings")
        guard settings == original.settings else { throw BedRemoteFailure.changed }
        if !request.isStopping {
            let capability: Capability = try await client.get("v1/capabilities")
            let status: Status = try await client.get("device/status", query: ["unit": "F"])
            let observation = capability.observations.device, now = Date()
            guard status.waterLevel == "ok", !status.isPriming, observation.freshness == "fresh",
                  observation.observedAt.flatMap(NextAlarmState.instant).map({ $0 <= now && now.timeIntervalSince($0) < 15 }) == true,
                  observation.expiresAt.flatMap(NextAlarmState.instant).map({ $0 > now }) == true else { throw BedRemoteFailure.unavailable }
            for (index, side) in original.sides.enumerated() {
                let target = status.temperatureControl?[side]?.targetTemperature
                guard let target, target.isFinite, target == Double(original.target[index] ?? -1) else { throw BedRemoteFailure.changed }
            }
        }
        var acknowledged = 0
        for side in original.sides {
            let action: NativeControlAction
            switch request.action {
            case .temperature: action = .init(kind: "temperature", side: side, temperature: request.temperatureF, holdMinutes: 30)
            case .stopTemperature: action = .init(kind: "power", side: side, powered: false)
            case .stopVibration: action = .init(kind: "vibration.clear", side: side)
            case .refresh: throw BedRemoteFailure.invalid
            }
            do {
                let attempt = try await controls.submit(action, validateBeforeSubmit: validateBeforeSubmit)
                guard attempt.receipt?.state == "acknowledged" else { throw BedRemoteFailure.unavailable }
                acknowledged += 1
            } catch {
                throw APIError.serverError(message: "\(acknowledged) of \(original.sides.count) sides acknowledged. Check command history on iPhone. This tap will not be repeated.")
            }
        }
        return "Controller acknowledged for \(reading.snapshot.assignment.lowercased()). Check the bed for its physical response."
    }
}
