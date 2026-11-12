import XCTest
@testable import Sleepypod

actor PersonalLearningTestServer: PersonalLearningTransport {
    var account: HouseholdSession
    var archivePage: PersonalLearningArchivePage
    var recordPage: PersonalLearningRecordPage
    var recorded: PersonalLearningDetail
    var failure: HouseholdFailure?
    private(set) var requests: [String] = []
    private var held: String?
    private var continuation: CheckedContinuation<Void, Never>?
    init() throws {
        account = try PersonalLearningFixtures.session(); archivePage = try PersonalLearningFixtures.archives()
        recordPage = try PersonalLearningFixtures.records(); recorded = try PersonalLearningFixtures.detail()
    }
    func configure(account: HouseholdSession? = nil, archives: PersonalLearningArchivePage? = nil,
                   records: PersonalLearningRecordPage? = nil, detail: PersonalLearningDetail? = nil, failure: HouseholdFailure? = nil) {
        if let account { self.account = account }; if let archives { archivePage = archives }
        if let records { recordPage = records }; if let detail { recorded = detail }; self.failure = failure
    }
    func hold(_ route: String) { held = route }
    func waitHeld() async throws {
        for _ in 0..<200 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HouseholdFailure.uncertain
    }
    func release() { continuation?.resume(); continuation = nil }
    private func pause(_ route: String) async {
        requests.append(route)
        if held == route { held = nil; await withCheckedContinuation { continuation = $0 } }
    }
    func session() async throws -> HouseholdSession { let result = account; await pause("session"); if let failure { throw failure }; return result }
    func archives(before: String?, limit: Int) async throws -> PersonalLearningArchivePage {
        let result = archivePage; await pause("archives"); if let failure { throw failure }; return result
    }
    func records(archiveId: String, after: Int, limit: Int) async throws -> PersonalLearningRecordPage {
        let result = recordPage; await pause("records"); if let failure { throw failure }; return result
    }
    func detail(recordId: String) async throws -> PersonalLearningDetail {
        let result = recorded; await pause("detail"); if let failure { throw failure }; return result
    }
}

@MainActor final class PersonalLearningWorkspaceTests: XCTestCase {
    private func workspace(_ server: PersonalLearningTestServer) throws -> PersonalLearningWorkspace {
        .init(connection: try PersonalLearningFixtures.connection(), client: server)
    }
    private func open(_ model: PersonalLearningWorkspace) async throws {
        await model.refresh()
        await model.openArchive(try XCTUnwrap(model.archives?.archives.first?.id))
        await model.openRecord(try XCTUnwrap(model.records?.records.first?.id))
    }
    func testExplicitReadsReauthorizeBeforeAndAfterEachResponseWithoutPersistingOrMutating() async throws {
        let server = try PersonalLearningTestServer(), model = try workspace(server)
        let initialRequests = await server.requests
        XCTAssertTrue(initialRequests.isEmpty)
        try await open(model)
        XCTAssertEqual(model.detail, try PersonalLearningFixtures.detail())
        XCTAssertFalse(model.busy); XCTAssertNil(model.error)
        let requests = await server.requests
        XCTAssertEqual(requests, ["session", "archives", "session", "session", "records", "session", "session", "detail", "session"])
        model.closeRecord()
        XCTAssertNil(model.detail); XCTAssertNotNil(model.records)
    }
    func testBackgroundInvalidationAndCloseDiscardLatePrivateReplies() async throws {
        for action in ["background", "invalidate", "close"] {
            let server = try PersonalLearningTestServer(), model = try workspace(server)
            await model.refresh(); await model.openArchive(try XCTUnwrap(model.archives?.archives.first?.id))
            let identifier = try XCTUnwrap(model.records?.records.first?.id)
            await server.hold("detail")
            let pending = Task { await model.openRecord(identifier) }
            try await server.waitHeld()
            if action == "background" { model.suspend() }
            if action == "invalidate" { model.invalidate() }
            if action == "close" { model.closeRecord() }
            await server.release(); await pending.value
            XCTAssertNil(model.detail); XCTAssertFalse(model.busy)
            if action != "close" { XCTAssertNil(model.archives); XCTAssertNil(model.records) }
        }
    }
    func testEveryIdentityOrCapabilityChangeWithdrawsVisibleRecords() async throws {
        for field in ["accountId", "householdRevision", "assignmentRevision", "personalLearningArchive"] {
            let server = try PersonalLearningTestServer(), model = try workspace(server)
            try await open(model)
            let updated: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalLearningFixtures.session()) {
                if field == "personalLearningArchive" {
                    var capabilities = $0["capabilities"] as! [String: Any]; capabilities[field] = false; $0["capabilities"] = capabilities
                } else { $0[field] = field == "accountId" ? UUID().uuidString : 2 }
            }
            await server.configure(account: updated); await model.checkAccess()
            XCTAssertNil(model.archives); XCTAssertNil(model.detail); XCTAssertTrue(model.isInvalidated)
        }
    }
    func testChangedAccountWhileDetailIsPendingIsRejectedByFinalSessionCheck() async throws {
        let server = try PersonalLearningTestServer(), model = try workspace(server)
        await model.refresh(); await model.openArchive(try XCTUnwrap(model.archives?.archives.first?.id))
        let identifier = try XCTUnwrap(model.records?.records.first?.id)
        await server.hold("detail")
        let pending = Task { await model.openRecord(identifier) }
        try await server.waitHeld()
        let changed: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalLearningFixtures.session()) { $0["householdRevision"] = 2 }
        await server.configure(account: changed); await server.release(); await pending.value
        XCTAssertNil(model.detail); XCTAssertNil(model.archives); XCTAssertTrue(model.isInvalidated)
    }
    func testPayloadFailureWithdrawsLibraryAndDoesNotRetry() async throws {
        let server = try PersonalLearningTestServer(), model = try workspace(server)
        try await open(model)
        let changed: PersonalLearningDetail = try PersonalHistoryFixtures.changed(PersonalLearningFixtures.detail()) { $0["payload"] = "different private content" }
        await server.configure(detail: changed)
        await model.openRecord(try XCTUnwrap(model.records?.records.first?.id))
        XCTAssertNil(model.detail); XCTAssertNil(model.records); XCTAssertNil(model.archives)
        XCTAssertFalse(model.error?.contains("different private") == true)
        let requests = await server.requests
        XCTAssertEqual(requests.filter { $0 == "detail" }.count, 2)
    }
    func testUnavailableLibraryAndRevocationNeverFallBackToOwnerHistory() async throws {
        let server = try PersonalLearningTestServer()
        let session: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalLearningFixtures.session()) {
            var capability = $0["capabilities"] as! [String: Any]; capability.removeValue(forKey: "personalLearningArchive"); $0["capabilities"] = capability
        }
        let model = PersonalLearningWorkspace(connection: PersonalHistoryFixtures.connection(session), client: server)
        await model.refresh()
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty); XCTAssertFalse(model.enabled)
        var revoked = 0
        let available = PersonalLearningWorkspace(connection: try PersonalLearningFixtures.connection(), client: server, revoked: { revoked += 1 })
        try await open(available)
        await server.configure(failure: .authentication); await available.checkAccess()
        XCTAssertEqual(revoked, 1); XCTAssertNil(available.archives); XCTAssertTrue(available.isInvalidated)
    }

    func testNavigationCancellationKeepsVerifiedLibraryButBackgroundWithdrawsIt() async throws {
        let server = try PersonalLearningTestServer(), model = try workspace(server)
        try await open(model)
        let original = model.detail
        await server.hold("session")
        let check = Task { await model.checkAccess() }
        try await server.waitHeld(); check.cancel(); await server.release(); await check.value
        XCTAssertEqual(model.detail, original); XCTAssertFalse(model.isInvalidated); XCTAssertNil(model.error)
        model.suspend()
        XCTAssertNil(model.archives); XCTAssertNil(model.detail)
    }

    func testParentClearsPrivateFilesOnBackgroundSignOutAndAccountRevision() async throws {
        for boundary in ["background", "signout", "revision"] {
            let account = try PersonalLearningFixtures.session(), server = try ArrangementTestServer(), learning = try PersonalLearningTestServer()
            await server.setSession(account)
            let vault = ArrangementTestVault(account), defaults = UserDefaults(suiteName: UUID().uuidString)!
            let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, learningClient: { _ in learning },
                capability: { false }, ownerEndpoint: { nil })
            parent.enter(); await parent.refresh()
            let child = try XCTUnwrap(parent.learning)
            try await open(child)
            let persisted = String(decoding: try JSONEncoder().encode(vault.state), as: UTF8.self)
            for field in ["payloadHash", "payloadBytes", "Felt comfortable", "contentHash"] { XCTAssertFalse(persisted.contains(field)) }
            if boundary == "background" { await parent.sceneChanged(active: false) }
            if boundary == "signout" { parent.signOut() }
            if boundary == "revision" {
                let changed: HouseholdSession = try PersonalHistoryFixtures.changed(account) { $0["householdRevision"] = 2 }
                await server.setSession(changed); await parent.refresh()
            }
            XCTAssertTrue(child.isInvalidated); XCTAssertNil(child.detail); XCTAssertNil(child.archives)
            XCTAssertFalse(parent.learning === child)
        }
    }

    func testRecordPaginationReplacesPageAndRejectsRepeatedOrdinal() async throws {
        let server = try PersonalLearningTestServer(), model = try workspace(server)
        let archives: PersonalLearningArchivePage = try PersonalHistoryFixtures.changed(PersonalLearningFixtures.archives()) {
            var rows = $0["archives"] as! [[String: Any]]; rows[0]["recordCount"] = 40; rows[0]["payloadBytes"] = 437 * 40; $0["archives"] = rows
        }
        func page(after: Int) throws -> PersonalLearningRecordPage {
            try PersonalHistoryFixtures.changed(PersonalLearningFixtures.records()) {
                let original = ($0["records"] as! [[String: Any]])[0]
                $0["records"] = (1...20).map { index in
                    var row = original; row["ordinal"] = after + index
                    row["recordId"] = String(format: "30000000-0000-4000-8000-%012d", after + index); return row
                }
                var query = $0["query"] as! [String: Any]; query["after"] = after; $0["query"] = query
                $0["nextOrdinal"] = after == 0 ? 20 : NSNull()
            }
        }
        await server.configure(archives: archives, records: try page(after: 0)); await model.refresh()
        await model.openArchive(try XCTUnwrap(model.archives?.archives.first?.id))
        XCTAssertEqual(model.records?.records.first?.ordinal, 1); XCTAssertEqual(model.records?.records.count, 20)
        await server.configure(records: try page(after: 20)); await model.nextRecords()
        XCTAssertEqual(model.records?.records.first?.ordinal, 21); XCTAssertEqual(model.records?.records.count, 20)
        XCTAssertNil(model.records?.nextOrdinal)
        await server.configure(records: try page(after: 0)); await model.openArchive(try XCTUnwrap(model.selected?.id))
        let repeated: PersonalLearningRecordPage = try PersonalHistoryFixtures.changed(page(after: 20)) {
            var rows = $0["records"] as! [[String: Any]]; rows[0]["ordinal"] = 20; $0["records"] = rows
        }
        await server.configure(records: repeated); await model.nextRecords()
        XCTAssertNil(model.records); XCTAssertNil(model.archives); XCTAssertNotNil(model.error)
    }

    func testPendingLibraryReadDoesNotBlockPersonalStop() async throws {
        let account: HouseholdSession = try PersonalHistoryFixtures.changed(PersonalLearningFixtures.session()) {
            var flags = $0["capabilities"] as! [String: Any]; flags["personalControls"] = true; $0["capabilities"] = flags
        }
        let server = try ArrangementTestServer(), learning = try PersonalLearningTestServer()
        await server.setSession(account); await learning.configure(account: account)
        let bed: PersonalBed = try PersonalHistoryFixtures.changed(PersonalControlFixtures.currentBed()) {
            var scope = $0["scope"] as! [String: Any]
            scope["podId"] = account.podId; scope["householdId"] = account.householdId; scope["sleeperId"] = account.selfSleeperId
            scope["sessionRevision"] = account.sessionRevision; scope["assignmentRevision"] = account.assignmentRevision; $0["scope"] = scope
        }
        let controls = PersonalTestServer(bed: bed, session: account), vault = ArrangementTestVault(account)
        let parent = HouseholdWorkspace(vault: vault, defaults: UserDefaults(suiteName: UUID().uuidString)!, client: { _ in server },
            personalClient: { _ in controls }, learningClient: { _ in learning }, capability: { false }, ownerEndpoint: { nil })
        parent.enter(); await parent.refresh()
        let child = try XCTUnwrap(parent.learning), temperature = try XCTUnwrap(parent.temperature)
        await temperature.refresh(); await learning.hold("archives")
        let reading = Task { await child.refresh() }; try await learning.waitHeld()
        await temperature.submit(.init(kind: "power", powered: false))
        let posts = await controls.posts
        XCTAssertEqual(posts.count, 1)
        let command = try JSONDecoder().decode(PersonalControlRequest.self, from: XCTUnwrap(posts.first))
        XCTAssertEqual(command.action.powered, false)
        await learning.release(); await reading.value
    }
}
