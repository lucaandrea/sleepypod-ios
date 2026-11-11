#if DEBUG
import Foundation
import FreeSleepKit

/// Synthetic maintenance is isolated from owner transports, Health and physical hardware.
@MainActor enum ArrangementMaintenancePreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--maintenance-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let server = try ArrangementMaintenancePreviewServer(mode: arguments[index + 1])
            let account = server.initialAccount
            let record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://maintenance-preview.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: account)
            let vault = MaintenancePreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "maintenance-preview")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            return HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, arrangementClient: { _ in server },
                maintenanceClient: { _ in server }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
}

@MainActor private final class MaintenancePreviewVault: HouseholdVault {
    var state: HouseholdVaultState
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}

private actor ArrangementMaintenancePreviewServer: HouseholdTransport, ArrangementReviewTransport, ArrangementMaintenanceTransport {
    nonisolated let initialAccount: HouseholdSession
    private var account: HouseholdSession
    private let approved: ArrangementReview
    private let mode: String
    private var operation: [String: Any]?

    init(mode: String) throws {
        self.mode = mode
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        var review = try Self.fixture("arrangement-review-v1", key: "ownerReview")
        review["state"] = "approved_for_separate_activation"; review["canActivate"] = true; review["canApprove"] = false
        review["createdAt"] = now - 5_000; review["expiresAt"] = now + 3_600_000
        for field in ["self", "partner"] {
            var person = review[field] as? [String: Any] ?? [:]; person["approved"] = true; review[field] = person
        }
        approved = try .decodeExact(JSONSerialization.data(withJSONObject: review))
        var raw = try Self.fixture("household-preparation-v1", key: "ownerSession")
        raw["podId"] = approved.podId; raw["householdId"] = approved.householdId; raw["selfSleeperId"] = approved.sleeperId
        raw["assignmentRevision"] = approved.assignmentRevision
        raw["arrangement"] = ["mode": "solo-anywhere", "effectiveAt": "2026-10-29T20:00:00Z"]
        raw["self"] = ["displayName": approved.person.displayName, "zones": ["left", "right"], "assignment": "solo"]
        var capabilities = raw["capabilities"] as? [String: Any] ?? [:]
        capabilities["arrangementReview"] = true; capabilities["arrangementMaintenance"] = true; capabilities["activateArrangement"] = true
        capabilities["personalControls"] = false; capabilities["personalRoutinePublication"] = false
        raw["capabilities"] = capabilities
        if !["activate", "held"].contains(mode) {
            raw["sessionRevision"] = 2; raw["assignmentRevision"] = 2
            raw["arrangement"] = ["mode": "assigned", "effectiveAt": "2026-11-11T15:00:00Z"]
            raw["self"] = ["displayName": approved.person.displayName, "zones": ["right"], "assignment": "right"]
        }
        initialAccount = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: raw))
        account = initialAccount
        let key = mode == "activate" ? "empty" : mode == "recover" ? "readyToRecover" : mode == "unknown" ? "restartSubmitted" : mode == "held" ? "held" : "committed"
        operation = try Self.fixture("household-maintenance-v1", key: key)["operation"] as? [String: Any]
        if mode == "held" { operation?["controllerRestarted"] = true }
    }
    private static func fixture(_ file: String, key: String) throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: file, withExtension: "json"),
              let value = try ArrangementJSON.object(Data(contentsOf: url))[key] as? [String: Any] else { throw HouseholdFailure.invalid }
        return value
    }
    func session() async throws -> HouseholdSession { account }
    func latest() async throws -> ArrangementIndex { .init(version: 1, review: operation == nil ? approved : nil) }
    func review(_ id: UUID) async throws -> ArrangementReview { approved }
    func send(_ action: ArrangementRequest.Action, body: Data) async throws -> ArrangementReview { throw HouseholdFailure.forbidden }
    func status(operationId: UUID?) async throws -> ArrangementMaintenanceStatus {
        if mode == "unavailable" { throw HouseholdFailure.unavailable }
        return try .decodeExact(JSONSerialization.data(withJSONObject: ["version": 1, "observedAt": Self.now,
            "expectedSessionRevision": account.sessionRevision, "expectedAssignmentRevision": account.assignmentRevision,
            "operation": operation.map { $0 as Any } ?? NSNull()]))
    }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    func cancellationPreview(operationId: UUID) async throws -> ArrangementCancellationPreview {
        try .decodeExact(JSONSerialization.data(withJSONObject: ["operationId": operationId.uuidString.lowercased(),
            "expectedSessionRevision": account.sessionRevision, "expectedAssignmentRevision": account.assignmentRevision,
            "controlDigest": String(repeating: "a", count: 64), "observedAt": Self.now]))
    }
    func send(_ request: ArrangementMaintenanceRequest, session: HouseholdSession) async throws -> ArrangementMaintenanceResult {
        _ = try ArrangementMaintenanceRequest.decodeExact(request.body, action: request.action, session: account, now: Self.now)
        let now = Self.now
        var envelope: [String: Any] = ["replayed": false]
        if request.action == .activate {
            operation = ["operationId": request.requestId, "reviewId": request.referenceId, "state": "committed",
                "createdAt": now, "committedAt": now, "controllerRestarted": false, "admission": "held_for_this_transition",
                "restart": NSNull(), "recovery": NSNull(), "cancellation": NSNull()]
            envelope["receipt"] = ["operationId": request.requestId, "reviewId": request.referenceId, "state": "committed",
                "createdAt": now, "committedAt": now, "admissionRevision": 2, "hardware": "held_for_runtime_recovery"]
            envelope["recovered"] = false
            var updated = try ArrangementJSON.object(JSONEncoder().encode(account))
            updated["sessionRevision"] = 2; updated["assignmentRevision"] = 2
            updated["arrangement"] = ["mode": "assigned", "effectiveAt": "2026-11-11T15:00:00Z"]
            updated["self"] = ["displayName": approved.person.displayName, "zones": ["right"], "assignment": "right"]
            account = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: updated))
        } else {
            guard var saved = operation else { throw HouseholdFailure.conflict }
            if request.action == .restart {
                let receipt: [String: Any] = ["operationId": request.referenceId, "requestId": request.requestId, "state": "submitted",
                    "requestedAt": now, "resultAt": now, "hardware": "held_for_runtime_recovery", "replayAllowed": false]
                saved["restart"] = receipt; envelope["receipt"] = receipt
            } else {
                let source = try Self.fixture("household-maintenance-v1", key: request.action == .recover ? "completed" : "cancelled")
                let field = request.action == .recover ? "recovery" : "cancellation"
                guard let completed = source["operation"] as? [String: Any], var receipt = completed[field] as? [String: Any] else { throw HouseholdFailure.invalid }
                receipt["requestId"] = request.requestId; receipt["operationId"] = request.referenceId; receipt["reviewId"] = saved["reviewId"]
                receipt["completedAt"] = now
                saved["state"] = request.action == .recover ? "completed" : "cancelled"; saved[field] = receipt; saved["admission"] = "open"
                envelope["receipt"] = receipt; envelope["automaticServices"] = "resumed"
            }
            operation = saved
        }
        return try .decodeExact(JSONSerialization.data(withJSONObject: envelope), request: request)
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard method == "GET" else { throw HouseholdFailure.forbidden }
        switch path {
        case "household/session": return try JSONEncoder().encode(account)
        case "me/preferences": return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: account.selfSleeperId, revision: 2, preferences: approved.person.preferences))
        case "me/routines": return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: account.selfSleeperId, revision: 2, status: "draft_only", routines: approved.person.week))
        case "household/devices": return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Preview phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8)
        case "household/invitations": return Data(#"{"invitations":[]}"#.utf8)
        default: throw HouseholdFailure.unavailable
        }
    }
}
#endif
