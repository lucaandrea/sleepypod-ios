import XCTest
@testable import Sleepypod

enum PersonalControlFixtures {
    static let instant = Date(timeIntervalSince1970: 1_793_314_800)
    static func data(_ key: String, file: String = "personal-controls-v1") throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: file, withExtension: "json"))
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(values[key]))
    }
    static func bed(_ key: String = "soloBed") throws -> PersonalBed { try JSONDecoder().decode(PersonalBed.self, from: data(key)) }
    static func session(for bed: PersonalBed, controls: Bool = true) throws -> HouseholdSession {
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: data("ownerSession", file: "household-preparation-v1")) as? [String: Any])
        values["podId"] = bed.scope.podId; values["householdId"] = bed.scope.householdId; values["selfSleeperId"] = bed.scope.sleeperId
        values["sessionRevision"] = bed.scope.sessionRevision; values["assignmentRevision"] = bed.scope.assignmentRevision
        values["arrangement"] = ["mode": bed.arrangement, "effectiveAt": "2026-10-29T20:00:00Z"]
        let zones = bed.availability == "unassigned" ? [] : bed.arrangement == "solo-anywhere" ? ["left", "right"] : bed.zones.map(\.side.rawValue)
        values["self"] = ["displayName": "Fixture Sleeper", "zones": zones, "assignment": zones.isEmpty ? "unassigned" : zones.count == 2 ? "solo" : zones[0]]
        var capabilities = try XCTUnwrap(values["capabilities"] as? [String: Any]); capabilities["personalControls"] = controls; values["capabilities"] = capabilities
        return try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: values))
    }
    static func changed(_ bed: PersonalBed, assignment: Int? = nil, configuration: String? = nil, side: String? = nil) throws -> PersonalBed {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bed)) as? [String: Any])
        var scope = try XCTUnwrap(value["scope"] as? [String: Any])
        if let assignment { scope["assignmentRevision"] = assignment }
        if let configuration { scope["configurationRevision"] = configuration }
        value["scope"] = scope
        if let side {
            value["arrangement"] = "assigned"
            value["routing"] = ["temperature": [side], "power": [side], "vibrationCancellation": [side], "scheduledVibration": [side], "routines": side]
            var zones = try XCTUnwrap(value["zones"] as? [[String: Any]]); zones[0]["side"] = side; value["zones"] = [zones[0]]
        }
        return try JSONDecoder().decode(PersonalBed.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func receipt(_ request: PersonalControlRequest, zones: [Side], state: String = "acknowledged") -> PersonalControlReceipt {
        .init(version: 1, requestId: request.requestId, scope: request.scope, action: request.action, issuedAt: request.issuedAt,
              expiresAt: request.expiresAt, receivedAt: request.issuedAt, finishedAt: state == "executing" ? nil : request.issuedAt + 200,
              lastDispatchAt: request.issuedAt + 100, state: state, reason: state == "unknown" ? "dispatch_outcome_unknown" : nil,
              dispatchCount: state == "unknown" ? 1 : 2, physicalVerification: "unverified", replayAllowed: false, resolvedZones: zones)
    }
}

@MainActor final class PersonalTestLedger {
    var attempts: [PersonalControlAttempt] = []
    var reject = false
    var active = true
    var date = PersonalControlFixtures.instant
    var uptime: TimeInterval = 100
    func save(_ attempt: PersonalControlAttempt) throws {
        if reject { throw HouseholdFailure.storage }
        if let index = attempts.firstIndex(where: { $0.id == attempt.id }) { attempts[index] = attempt }
        else { attempts.append(attempt) }
    }
    func workspace(_ server: PersonalTestServer, session: HouseholdSession) -> PersonalTemperatureWorkspace {
        let connection = PersonalBedConnection(id: UUID(), endpoint: URL(string: "https://personal-fixture.invalid")!, token: String(repeating: "A", count: 43), session: session)
        return .init(connection: connection, client: server, unit: .fahrenheit,
                     permitted: { self.active }, load: { self.attempts }, save: { try self.save($0) }, now: { self.date }, uptime: { self.uptime })
    }
}

actor PersonalTestServer: PersonalBedTransport {
    var currentSession: HouseholdSession
    var snapshot: PersonalBed
    var posts: [Data] = []
    var lookups: [UUID] = []
    var sessions = 0
    var beds = 0
    var receipts: [UUID: PersonalControlReceipt] = [:]
    var postFailure: HouseholdFailure?
    var sessionFailure: HouseholdFailure?
    var missingReceipt = false
    var outcome = "acknowledged"
    private var heldRoute: String?
    private var continuation: CheckedContinuation<Void, Never>?
    var onPost: (@Sendable (Data) async -> Void)?
    init(bed: PersonalBed, session: HouseholdSession) { snapshot = bed; currentSession = session }
    func configure(postFailure: HouseholdFailure? = nil, sessionFailure: HouseholdFailure? = nil, outcome: String = "acknowledged", missingReceipt: Bool = false) {
        self.postFailure = postFailure; self.sessionFailure = sessionFailure; self.outcome = outcome; self.missingReceipt = missingReceipt
    }
    func setBed(_ value: PersonalBed) { snapshot = value }
    func setSession(_ value: HouseholdSession) { currentSession = value }
    func setReceipt(_ value: PersonalControlReceipt) { receipts[value.requestId] = value }
    func setOnPost(_ action: @escaping @Sendable (Data) async -> Void) { onPost = action }
    func hold(_ route: String) { heldRoute = route }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    private func pause(_ route: String) async {
        if heldRoute == route { heldRoute = nil; await withCheckedContinuation { continuation = $0 } }
    }
    func session() async throws -> HouseholdSession {
        sessions += 1; let value = currentSession; await pause("session")
        if let sessionFailure { throw sessionFailure }; return value
    }
    func bed() async throws -> PersonalBed { beds += 1; let value = snapshot; await pause("bed"); return value }
    func submit(_ body: Data) async throws -> PersonalControlReceipt {
        posts.append(body); await onPost?(body)
        let request = try JSONDecoder().decode(PersonalControlRequest.self, from: body)
        let receipt = PersonalControlFixtures.receipt(request, zones: snapshot.routing.zones(for: request.action), state: outcome)
        receipts[request.requestId] = receipt
        await pause("post")
        if let postFailure { throw postFailure }; return receipt
    }
    func receipt(_ requestId: UUID) async throws -> PersonalControlReceipt {
        lookups.append(requestId)
        let value = receipts[requestId]
        await pause("receipt")
        if missingReceipt { throw PersonalControlFailure.missingReceipt }
        return try XCTUnwrap(value)
    }
}
