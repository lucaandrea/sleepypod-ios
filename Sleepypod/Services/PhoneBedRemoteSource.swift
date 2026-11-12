import Foundation

/// Selects one account boundary. A personal account never falls back to the installation-owner key.
@MainActor final class PhoneBedRemoteSource: BedRemoteSource {
    private let household: HouseholdWorkspace
    private let owner: any BedRemoteSource
    private var personal: (lease: UUID, model: PersonalTemperatureWorkspace, bed: PersonalBed)?
    var context: [String] { household.active ? ["personal"] + household.remoteContext : ["owner"] + owner.context }
    init(household: HouseholdWorkspace, owner: any BedRemoteSource) { self.household = household; self.owner = owner }
    func prepareRead() throws {
        if household.active { try household.prepareRemoteAccess() }
        else { try owner.prepareRead() }
    }
    func read() async throws -> BedRemoteReading {
        try prepareRead()
        let expected = context
        if !household.active {
            personal = nil
            let reading = try await owner.read()
            guard expected == context else { throw BedRemoteFailure.changed }
            return .init(context: expected, snapshot: reading.snapshot)
        }
        let (session, model) = try await household.prepareRemoteTemperature()
        guard expected == context, let bed = model.bed else { throw BedRemoteFailure.changed }
        let nextAlarm: String
        var wake: BedRemoteWake?
        do {
            let plan = try await household.readRemoteWake(for: bed).plan
            nextAlarm = BedRemoteWakeSummary.text(plan)
            wake = BedRemoteWakeSummary.occurrence(plan)
        }
        catch let failure as HouseholdFailure where [.changedIdentity, .authentication, .forbidden, .conflict, .invalid].contains(failure) { throw failure }
        catch { nextAlarm = "Next wake unavailable. Open your personal account on iPhone and refresh the current plan." }
        guard expected == context else { throw BedRemoteFailure.changed }
        let now = Date(), fresh = bed.observation.isFresh(at: now)
        let zones = bed.zones.map { zone in
            BedRemoteSnapshot.Zone(id: zone.side.rawValue, measuredF: fresh ? zone.measuredTemperatureF : nil,
                requestedF: zone.requestedTargetF.map { Int($0.rounded()) }, powered: fresh ? zone.reportedPowered : nil)
        }
        let snapshot = BedRemoteSnapshot(lease: UUID(), receivedAt: now, expiresAt: now.addingTimeInterval(30),
            observationAt: (fresh ? bed.observation.observedAt : nil).map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            person: session.person.displayName, assignment: session.assignmentLabel, zones: zones,
            nextAlarm: nextAlarm,
            canAdjust: model.canAdjust, canStop: model.canStopPower && model.canStopVibration,
            explanation: model.canAdjust ? "Manual temperature hold · 30 minutes" : "Check the bed or pending commands on iPhone.", wake: wake)
        try snapshot.validate()
        personal = (snapshot.lease, model, bed)
        return .init(context: expected, snapshot: snapshot)
    }
    func perform(_ request: BedRemoteRequest, reviewed: BedRemoteReading,
                 validateBeforeSubmit: @escaping @MainActor () throws -> Void) async throws -> String {
        guard context == reviewed.context else { throw BedRemoteFailure.changed }
        if !household.active {
            return try await owner.perform(request, reviewed: .init(context: owner.context, snapshot: reviewed.snapshot), validateBeforeSubmit: validateBeforeSubmit)
        }
        guard let personal, personal.lease == reviewed.snapshot.lease else { throw BedRemoteFailure.changed }
        let action: PersonalControlAction
        switch request.action {
        case .temperature: action = .init(kind: "temperature", temperatureF: request.temperatureF, holdMinutes: 30)
        case .stopTemperature: action = .init(kind: "power", powered: false)
        case .stopVibration: action = .init(kind: "vibration.clear")
        case .refresh: throw BedRemoteFailure.invalid
        }
        let attempt = await personal.model.submitWithReceipt(action, validateBeforeSubmit: { bed in
            try validateBeforeSubmit()
            guard bed.scope == personal.bed.scope, bed.routing == personal.bed.routing else { throw BedRemoteFailure.changed }
            if !request.isStopping {
                guard bed.zones.map(\.requestedTargetF) == personal.bed.zones.map(\.requestedTargetF) else { throw BedRemoteFailure.changed }
            }
        })
        guard let receipt = attempt?.receipt, receipt.state == "acknowledged" else {
            throw APIError.serverError(message: personal.model.error ?? "Check the command receipt in your iPhone account. This tap has not been repeated.")
        }
        return receipt.message
    }
}
