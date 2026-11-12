import XCTest
@testable import Sleepypod

@MainActor final class MaintenanceTestContext {
    var now = MaintenanceFixtures.now
    var permitted = true
    var entered = 0
    var finished = 0
    var revoked = 0
    func workspace(_ server: MaintenanceTestServer, reviews: ArrangementTestServer, session: HouseholdSession) -> ArrangementMaintenanceWorkspace {
        .init(connection: ArrangementFixtures.connection(session), client: server, reviews: reviews,
              permitted: { self.permitted }, entered: { self.entered += 1 }, finished: { self.finished += 1 },
              revoked: { self.revoked += 1 }, now: { self.now })
    }
}

actor MaintenanceTestServer: ArrangementMaintenanceTransport {
    var account: HouseholdSession
    var now = MaintenanceFixtures.now
    var operation: [String: Any]?
    var posts: [ArrangementMaintenanceRequest.Action] = []
    var postFailure: HouseholdFailure?
    var failBeforeWrite = false
    private(set) var previewReads = 0
    private var previewDigest = String(repeating: "a", count: 64)
    private var previewClockOffset: Int64 = 0
    private var held: String?
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ key: String = "committed") throws {
        account = try MaintenanceFixtures.session()
        operation = try ArrangementJSON.object(MaintenanceFixtures.data(key))["operation"] as? [String: Any]
    }
    func configure(key: String? = nil, failure: HouseholdFailure? = nil, now: Int64? = nil, beforeWrite: Bool = false) throws {
        if let key { operation = try ArrangementJSON.object(MaintenanceFixtures.data(key))["operation"] as? [String: Any] }
        postFailure = failure
        failBeforeWrite = beforeWrite
        if let now { self.now = now }
    }
    func changeAccount(_ value: HouseholdSession) { account = value }
    func markRestarted() { operation?["controllerRestarted"] = true }
    func configurePreview(digest: String? = nil, clockOffset: Int64 = 0) {
        if let digest { previewDigest = digest }
        previewClockOffset = clockOffset
    }
    func hold(_ route: String) { held = route }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    private func pause(_ route: String) async {
        if held == route { held = nil; await withCheckedContinuation { continuation = $0 } }
    }
    func session() async throws -> HouseholdSession {
        let value = account; await pause("session"); return value
    }
    func status(operationId: UUID?) async throws -> ArrangementMaintenanceStatus {
        let value = try ArrangementMaintenanceStatus.decodeExact(JSONSerialization.data(withJSONObject: ["version": 1,
            "observedAt": now, "expectedSessionRevision": account.sessionRevision, "expectedAssignmentRevision": account.assignmentRevision,
            "operation": operation.map { $0 as Any } ?? NSNull()]))
        await pause("status"); return value
    }
    func cancellationPreview(operationId: UUID) async throws -> ArrangementCancellationPreview {
        previewReads += 1
        let value = try ArrangementCancellationPreview.decodeExact(JSONSerialization.data(withJSONObject: ["operationId": operationId.uuidString.lowercased(),
            "expectedSessionRevision": account.sessionRevision, "expectedAssignmentRevision": account.assignmentRevision,
            "controlDigest": previewDigest, "observedAt": now + previewClockOffset]))
        await pause("preview")
        return value
    }
    func send(_ request: ArrangementMaintenanceRequest, session: HouseholdSession) async throws -> ArrangementMaintenanceResult {
        _ = try ArrangementMaintenanceRequest.decodeExact(request.body, action: request.action, session: account, now: now)
        posts.append(request.action)
        if failBeforeWrite, let postFailure { throw postFailure }
        var envelope: [String: Any] = ["replayed": false]
        if request.action == .activate {
            operation = ["operationId": request.requestId, "reviewId": request.referenceId, "state": "committed",
                "createdAt": now, "committedAt": now, "controllerRestarted": false, "admission": "held_for_this_transition",
                "restart": NSNull(), "recovery": NSNull(), "cancellation": NSNull()]
            account = try PersonalRoutineFixtures.changed(account) {
                $0["sessionRevision"] = 2; $0["assignmentRevision"] = 2
                $0["arrangement"] = ["mode": "assigned", "effectiveAt": "2026-11-11T15:00:00Z"]
                $0["self"] = ["displayName": "Owner", "zones": ["right"], "assignment": "right"]
            }
            envelope["receipt"] = ["operationId": request.requestId, "reviewId": request.referenceId, "state": "committed",
                "createdAt": now, "committedAt": now, "admissionRevision": 2, "hardware": "held_for_runtime_recovery"]
            envelope["recovered"] = false
        } else {
            var saved = try XCTUnwrap(operation)
            if request.action == .restart {
                let receipt: [String: Any] = ["operationId": request.referenceId, "requestId": request.requestId,
                    "state": "submitted", "requestedAt": now, "resultAt": now,
                    "hardware": "held_for_runtime_recovery", "replayAllowed": false]
                saved["restart"] = receipt; envelope["receipt"] = receipt
            } else {
                let source = try ArrangementJSON.object(MaintenanceFixtures.data(request.action == .recover ? "completed" : "cancelled"))
                let complete = try XCTUnwrap(source["operation"] as? [String: Any])
                let field = request.action == .recover ? "recovery" : "cancellation"
                var receipt = try XCTUnwrap(complete[field] as? [String: Any])
                receipt["requestId"] = request.requestId; receipt["operationId"] = request.referenceId
                receipt["reviewId"] = saved["reviewId"]; receipt["completedAt"] = now
                saved["state"] = request.action == .recover ? "completed" : "cancelled"
                saved[field] = receipt; saved["admission"] = "open"
                envelope["receipt"] = receipt; envelope["automaticServices"] = "resumed"
            }
            operation = saved
        }
        await pause("post")
        if let postFailure { throw postFailure }
        return try ArrangementMaintenanceResult.decodeExact(JSONSerialization.data(withJSONObject: envelope), request: request)
    }
}
