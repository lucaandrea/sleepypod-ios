import XCTest
@testable import Sleepypod

enum LearningRemovalFixtures {
    static func session(enabled: Bool = true) throws -> HouseholdSession {
        try PersonalHistoryFixtures.changed(PersonalLearningFixtures.session()) {
            var capabilities = $0["capabilities"] as! [String: Any]
            capabilities["personalLearningRemoval"] = enabled; $0["capabilities"] = capabilities
        }
    }
    static func request() throws -> PersonalLearningRemovalRequest {
        let detail = try PersonalLearningFixtures.detail(), session = try session()
        return .init(version: 1, requestId: UUID().uuidString.lowercased(), expectedSessionRevision: session.sessionRevision,
                     expectedAssignmentRevision: session.assignmentRevision, recordId: detail.recordId, archiveId: detail.archiveId,
                     expectedPayloadHash: detail.payloadHash, confirmRemoveArchivedCopy: true)
    }
    static func response(_ request: PersonalLearningRemovalRequest, exists: Bool = true) throws -> PersonalLearningRemovalResponse {
        let detail = try PersonalLearningFixtures.detail()
        return .init(version: 1, generatedAt: detail.generatedAt, scope: detail.scope,
                     interpretation: "archived_copy_removal_not_source_deletion", receipt: exists ? .init(requestId: request.requestId,
                        recordId: request.recordId, archiveId: request.archiveId, payloadHash: request.expectedPayloadHash,
                        removedAt: detail.generatedAt, outcome: "content_removed") : nil)
    }
}

final class PersonalLearningRemovalContractTests: XCTestCase {
    func testReceiptMustMatchReviewedCopyAndCurrentPersonalScope() throws {
        let request = try LearningRemovalFixtures.request(), response = try LearningRemovalFixtures.response(request)
        let session = try LearningRemovalFixtures.session(), capturedAt = try XCTUnwrap(PersonalLearningFixtures.archives().archives.first).capturedAt
        try response.validate(for: session, request: request, capturedAt: capturedAt)
        for field in ["requestId", "recordId", "archiveId", "payloadHash", "removedAt", "outcome"] {
            let changed: PersonalLearningRemovalResponse = try PersonalHistoryFixtures.changed(response) { object in
                var receipt = object["receipt"] as! [String: Any]
                receipt[field] = field == "removedAt" ? response.generatedAt + 1 : "wrong"
                object["receipt"] = receipt
            }
            XCTAssertThrowsError(try changed.validate(for: session, request: request, capturedAt: capturedAt), field)
        }
        let changed: HouseholdSession = try PersonalHistoryFixtures.changed(session) { $0["accountId"] = UUID().uuidString }
        XCTAssertThrowsError(try response.validate(for: changed, request: request, capturedAt: capturedAt))
        let old: PersonalLearningRemovalResponse = try PersonalHistoryFixtures.changed(response) { object in
            var receipt = object["receipt"] as! [String: Any]; receipt["removedAt"] = capturedAt - 1; object["receipt"] = receipt
        }
        XCTAssertThrowsError(try old.validate(for: session, request: request, capturedAt: capturedAt))
    }
    func testNullReceiptIsUnknownAndExtraPrivateFieldsAreRejected() throws {
        let request = try LearningRemovalFixtures.request(), response = try LearningRemovalFixtures.response(request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        object["receipt"] = NSNull()
        XCTAssertNil(try PersonalLearningRemovalResponse.decodeExact(JSONSerialization.data(withJSONObject: object)).receipt)
        object.removeValue(forKey: "receipt")
        XCTAssertThrowsError(try PersonalLearningRemovalResponse.decodeExact(JSONSerialization.data(withJSONObject: object)))
        object["receipt"] = NSNull(); object["payload"] = "private body"
        XCTAssertThrowsError(try PersonalLearningRemovalResponse.decodeExact(JSONSerialization.data(withJSONObject: object)))
    }
    func testReviewMetadataContainsNoPayloadAndCannotChangeOtherRows() throws {
        let detail = try PersonalLearningFixtures.detail(), page = try PersonalLearningFixtures.records()
        XCTAssertNil(detail.removingPayload.payload); XCTAssertTrue(detail.removingPayload.redacted)
        XCTAssertEqual(detail.removingPayload.payloadHash, detail.payloadHash)
        let removed = page.removingPayload(detail.recordId)
        XCTAssertEqual(removed.contentHash, page.contentHash)
        XCTAssertEqual(removed.records.filter { $0.id != detail.recordId }, page.records.filter { $0.id != detail.recordId })
        XCTAssertTrue(try XCTUnwrap(removed.records.first { $0.id == detail.recordId }).redacted)
    }
}

actor LearningRemovalTestServer: PersonalLearningTransport {
    let reader: PersonalLearningTestServer
    private(set) var posted: [PersonalLearningRemovalRequest] = []
    private(set) var receiptReads = 0
    var loseReply = false
    var receiptExists = true
    var mismatch = false
    private var holdRemoval = false
    private var continuation: CheckedContinuation<Void, Never>?
    init() throws { reader = try PersonalLearningTestServer() }
    func configure(loseReply: Bool = false, receiptExists: Bool = true, hold: Bool = false, mismatch: Bool = false) {
        self.loseReply = loseReply; self.receiptExists = receiptExists; holdRemoval = hold; self.mismatch = mismatch
    }
    func waitHeld() async throws {
        for _ in 0..<200 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HouseholdFailure.uncertain
    }
    func release() { continuation?.resume(); continuation = nil }
    func session() async throws -> HouseholdSession { try await reader.session() }
    func archives(before: String?, limit: Int) async throws -> PersonalLearningArchivePage { try await reader.archives(before: before, limit: limit) }
    func records(archiveId: String, after: Int, limit: Int) async throws -> PersonalLearningRecordPage {
        try await reader.records(archiveId: archiveId, after: after, limit: limit)
    }
    func detail(recordId: String) async throws -> PersonalLearningDetail { try await reader.detail(recordId: recordId) }
    func remove(_ request: PersonalLearningRemovalRequest) async throws -> PersonalLearningRemovalResponse {
        posted.append(request)
        if holdRemoval { await withCheckedContinuation { continuation = $0 } }
        if loseReply { throw HouseholdFailure.uncertain }
        return try LearningRemovalFixtures.response(mismatch ? LearningRemovalFixtures.request() : request)
    }
    func removalReceipt(requestId: String) async throws -> PersonalLearningRemovalResponse {
        receiptReads += 1
        guard let request = posted.first, request.requestId == requestId else { throw HouseholdFailure.invalid }
        return try LearningRemovalFixtures.response(request, exists: receiptExists)
    }
}

@MainActor final class PersonalLearningRemovalWorkspaceTests: XCTestCase {
    private func open(_ server: LearningRemovalTestServer, enabled: Bool = true) async throws -> PersonalLearningWorkspace {
        let session = try LearningRemovalFixtures.session(enabled: enabled)
        await server.reader.configure(account: session)
        let model = PersonalLearningWorkspace(connection: PersonalHistoryFixtures.connection(session), client: server)
        await model.refresh(); await model.openArchive(try XCTUnwrap(model.archives?.archives.first?.id))
        await model.openRecord(try XCTUnwrap(model.records?.records.first?.id))
        return model
    }
    func testReviewAndCancelKeepContentAndNeverSendRequest() async throws {
        let server = try LearningRemovalTestServer(), model = try await open(server), original = model.detail
        model.reviewRemoval(); XCTAssertEqual(model.removal?.phase, .review); XCTAssertEqual(model.detail, original)
        model.cancelRemoval(); XCTAssertNil(model.removal); XCTAssertEqual(model.detail, original)
        await model.confirmRemoval()
        let posts = await server.posted
        XCTAssertTrue(posts.isEmpty)
    }
    func testConfirmedRemovalRedactsOnlyReviewedCopyAndCannotResend() async throws {
        let server = try LearningRemovalTestServer(), model = try await open(server)
        model.reviewRemoval(); await model.confirmRemoval()
        XCTAssertEqual(model.removal?.phase, .removed); XCTAssertNil(model.detail?.payload)
        XCTAssertTrue(model.records?.records.first?.redacted == true)
        await model.confirmRemoval(); await model.checkRemovalReceipt()
        let posts = await server.posted, reads = await server.receiptReads
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(reads, 0)
    }
    func testLostReplyChecksReceiptWithoutAnotherMutationAndNullStaysUnknown() async throws {
        let server = try LearningRemovalTestServer(), model = try await open(server)
        await server.configure(loseReply: true, receiptExists: false)
        model.reviewRemoval(); await model.confirmRemoval()
        XCTAssertEqual(model.removal?.phase, .uncertain); XCTAssertNil(model.detail)
        await model.confirmRemoval(); await model.checkRemovalReceipt()
        XCTAssertEqual(model.removal?.phase, .uncertain); XCTAssertNil(model.removal?.receipt)
        await server.configure(); await model.checkRemovalReceipt()
        XCTAssertEqual(model.removal?.phase, .removed)
        let posts = await server.posted, reads = await server.receiptReads
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(reads, 2)
    }
    func testBackgroundCloseAndAccountChangesDiscardLateReceipt() async throws {
        for boundary in ["background", "close", "invalidate", "account"] {
            let server = try LearningRemovalTestServer(), model = try await open(server)
            await server.configure(hold: true); model.reviewRemoval()
            let pending = Task { await model.confirmRemoval() }
            try await server.waitHeld(); XCTAssertNil(model.detail)
            if boundary == "background" { model.suspend() }
            if boundary == "close" { model.closeRecord() }
            if boundary == "invalidate" { model.invalidate() }
            if boundary == "account" {
                let changed: HouseholdSession = try PersonalHistoryFixtures.changed(LearningRemovalFixtures.session()) { $0["accountId"] = UUID().uuidString }
                await server.reader.configure(account: changed)
            }
            await server.release(); await pending.value
            XCTAssertNil(model.detail); XCTAssertNil(model.removal); XCTAssertFalse(model.busy)
        }
    }
    func testUnavailableCapabilityAndRevokedPreflightNeverPost() async throws {
        let server = try LearningRemovalTestServer(), disabled = try await open(server, enabled: false)
        disabled.reviewRemoval(); await disabled.confirmRemoval(); XCTAssertNil(disabled.removal)
        let model = try await open(server)
        model.reviewRemoval(); await server.reader.configure(failure: .authentication); await model.confirmRemoval()
        XCTAssertTrue(model.isInvalidated); XCTAssertNil(model.removal)
        let posts = await server.posted
        XCTAssertTrue(posts.isEmpty)
    }
    func testMismatchedReceiptNeverConfirmsRemoval() async throws {
        let server = try LearningRemovalTestServer(), model = try await open(server)
        await server.configure(mismatch: true); model.reviewRemoval(); await model.confirmRemoval()
        XCTAssertEqual(model.removal?.phase, .uncertain); XCTAssertNil(model.detail); XCTAssertNil(model.removal?.receipt)
    }
}
