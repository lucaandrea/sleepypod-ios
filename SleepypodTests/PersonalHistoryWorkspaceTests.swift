import XCTest
@testable import Sleepypod

@MainActor final class PersonalHistoryWorkspaceTests: XCTestCase {
    func testLoadsOwnCompleteRecordsAndReauthorizesDetailWithoutPersistence() async throws {
        let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
        await model.refresh(); XCTAssertTrue(model.loaded); XCTAssertEqual(model.records.count, 1)
        let record = try XCTUnwrap(model.records.first)
        await model.loadDetail(record.id)
        XCTAssertEqual(model.detail?.record, record)
        let requests = await server.requests; XCTAssertEqual(requests, ["session", "first", "session", record.id])
        model.suspend(); XCTAssertNil(model.detail); XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.query)
        await model.loadDetail(record.id); XCTAssertEqual(model.detail?.record, record)
        let relaunched = try context.workspace(server); XCTAssertTrue(relaunched.records.isEmpty); XCTAssertNil(relaunched.detail)
    }
    func testFilterAndWindowChangesImmediatelyDiscardTheSnapshot() async throws {
        let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
        await model.refresh(); model.kind = .vitals
        XCTAssertTrue(model.records.isEmpty); XCTAssertFalse(model.loaded)
        await server.configure(pages: [try PersonalHistoryFixtures.page("vitalsPage")]); await model.refresh()
        XCTAssertEqual(model.records.first?.payload.kind, .vitals)
        model.window = .quarter; XCTAssertTrue(model.records.isEmpty); await model.refresh()
        XCTAssertEqual(try XCTUnwrap(model.query).endsAt - XCTUnwrap(model.query).startsAt, 90 * 86_400_000)
    }
    func testOpaqueCursorRetainsExactQueryAndAppendsOnlySameSnapshot() async throws {
        let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
        let first = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.page()) { $0["nextCursor"] = "opaque /+?= cursor" }
        let older = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.page()) { value in
            var records = try XCTUnwrap(value["records"] as? [[String: Any]])
            records[0]["id"] = "10000000-0000-4000-8000-000000000099"
            records[0]["startsAt"] = 1_793_224_800_000 as Int64; records[0]["endsAt"] = 1_793_253_600_000 as Int64; value["records"] = records
        }
        await server.configure(pages: [first, older]); await model.refresh(); let query = model.query
        XCTAssertTrue(model.canLoadMore); context.now += 3_600_000; await model.loadMore()
        XCTAssertEqual(model.records.count, 2); XCTAssertEqual(model.query, query); XCTAssertFalse(model.canLoadMore)
        let queries = await server.queries; XCTAssertEqual(queries, [query, query].compactMap { $0 })
        let requests = await server.requests; XCTAssertEqual(requests, ["session", "first", "session", "opaque /+?= cursor"])
    }
    func testStaleCursorDuplicateNewerRecordAndAttributionChangesDiscardAllPages() async throws {
        for mode in ["stale", "duplicate", "revision", "order", "loop"] {
            let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
            let first = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.page()) { $0["nextCursor"] = "cursor" }
            let second = try PersonalHistoryFixtures.changed(first) { value in
                value["nextCursor"] = mode == "loop" ? "cursor" : NSNull()
                if mode == "revision" { value["attributionRevision"] = 3 }
                if mode != "duplicate" {
                    var records = try XCTUnwrap(value["records"] as? [[String: Any]])
                    records[0]["id"] = UUID().uuidString
                    if mode == "order" { records[0]["startsAt"] = 1_793_311_201_000 as Int64; records[0]["endsAt"] = 1_793_340_001_000 as Int64 }
                    value["records"] = records
                }
            }
            await server.configure(pages: [first, second]); await model.refresh()
            if mode == "stale" { await server.configure(failure: .conflict) }
            await model.loadMore(); XCTAssertFalse(model.loaded, mode); XCTAssertTrue(model.records.isEmpty, mode); XCTAssertNil(model.nextCursor)
            XCTAssertNotNil(model.error)
        }
    }
    func testAllChangedScopesCapabilitiesAndRevocationsHidePrivateBodies() async throws {
        for field in ["podId", "householdId", "accountId", "selfSleeperId", "sessionRevision", "householdRevision", "assignmentRevision", "capabilities"] {
            let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
            await model.refresh()
            let changed = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.session()) { value in
                if field == "capabilities" { var flags = try XCTUnwrap(value[field] as? [String: Any]); flags["personalHistory"] = false; value[field] = flags }
                else { value[field] = field.hasSuffix("Revision") ? 2 : UUID().uuidString }
            }
            await server.setSession(changed); await model.refresh()
            XCTAssertTrue(model.records.isEmpty); XCTAssertTrue(model.isInvalidated)
        }
        let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
        await model.refresh(); await server.configure(sessionFailure: .authentication); await model.refresh()
        XCTAssertTrue(model.records.isEmpty); XCTAssertEqual(context.revocations, 1); XCTAssertFalse(model.enabled)
    }
    func testDisabledAndInvalidQuerySendNoRequest() async throws {
        let server = try PersonalHistoryTestServer(enabled: false), context = PersonalHistoryTestContext()
        let model = try context.workspace(server, session: PersonalHistoryFixtures.session(enabled: false))
        await model.refresh(); await model.loadMore(); await model.loadDetail(UUID().uuidString)
        let requests = await server.requests; XCTAssertTrue(requests.isEmpty)
        let enabled = try PersonalHistoryTestServer(); context.now = -1
        await (try context.workspace(enabled)).refresh()
        let invalid = await enabled.requests; XCTAssertTrue(invalid.isEmpty)
    }
    func testLateReadCannotCrossAccountBackgroundOrFilterBoundary() async throws {
        for route in ["session", "page", "detail"] {
            for boundary in ["account", "background", "filter"] {
                let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
                await model.refresh(); let id = try XCTUnwrap(model.records.first?.id)
                await server.hold(route)
                let task = Task { if route == "detail" { await model.loadDetail(id) } else { await model.refresh() } }
                await server.waitHeld()
                if boundary == "account" { model.invalidate() } else if boundary == "background" { model.suspend() } else { model.kind = .vitals }
                await server.release(); await task.value
                XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.detail); XCTAssertFalse(model.loaded); XCTAssertFalse(model.busy)
            }
        }
    }
    func testDetailMismatchAndAbortedReadsClearOldRecordsAndRequireFreshSession() async throws {
        for failure: HouseholdFailure in [.unavailable, .forbidden, .conflict, .uncertain, .invalid, .rateLimited] {
            let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
            await model.refresh(); let id = try XCTUnwrap(model.records.first?.id)
            await server.configure(failure: failure); await model.loadDetail(id)
            XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.detail); XCTAssertFalse(model.loaded)
            await server.configure(); await model.refresh(); XCTAssertTrue(model.loaded)
            let reads = await server.requests; XCTAssertEqual(reads.filter { $0 == "session" }.count, 3)
        }
        for field in ["id", "attributionRevision", "payload"] {
            let server = try PersonalHistoryTestServer(), context = PersonalHistoryTestContext(), model = try context.workspace(server)
            await model.refresh(); let id = try XCTUnwrap(model.records.first?.id)
            let changed = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.detail()) { value in
                if field == "attributionRevision" { value[field] = 3 }
                else {
                    var record = try XCTUnwrap(value["record"] as? [String: Any])
                    if field == "id" { record[field] = UUID().uuidString }
                    else { record[field] = ["kind": "presence", "reportedPresenceSeconds": 60, "exits": 0, "interpretation": "bed_presence_not_sleep"] }
                    value["record"] = record
                }
            }
            await server.configure(detail: changed); await model.loadDetail(id)
            XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.detail)
        }
    }
    func testParentKeepsRecordingsEphemeralAndReplacesChildForHouseholdRevision() async throws {
        let account = try PersonalHistoryFixtures.session(), server = try ArrangementTestServer(), history = try PersonalHistoryTestServer()
        await server.setSession(account)
        let vault = ArrangementTestVault(account), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, historyClient: { _ in history }, capability: { false }, ownerEndpoint: { nil })
        parent.enter(); await parent.refresh(); let child = try XCTUnwrap(parent.history)
        await child.refresh(); XCTAssertTrue(child.loaded)
        let stored = String(decoding: try JSONEncoder().encode(vault.state), as: UTF8.self)
        for key in ["reportedPresenceSeconds", "recordedSide", "attributionRevision", "nextCursor"] { XCTAssertFalse(stored.contains(key)) }
        let changed = try PersonalHistoryFixtures.changed(account) { $0["householdRevision"] = 2 }
        await server.setSession(changed); await parent.refresh()
        XCTAssertTrue(child.isInvalidated); XCTAssertTrue(child.records.isEmpty); XCTAssertFalse(parent.history === child)
        let replacement = try XCTUnwrap(parent.history); replacement.invalidate(); await parent.refresh(); XCTAssertFalse(parent.history === replacement)
        parent.signOut(); XCTAssertNil(parent.history)
    }
    func testPendingHistoryReadDoesNotBlockStopThroughSharedParent() async throws {
        let session = try PersonalHistoryFixtures.changed(PersonalHistoryFixtures.session()) {
            var flags = try XCTUnwrap($0["capabilities"] as? [String: Any]); flags["personalControls"] = true; $0["capabilities"] = flags
        }
        let server = try ArrangementTestServer(), history = try PersonalHistoryTestServer(); await server.setSession(session); await history.setSession(session)
        let bed = try PersonalHistoryFixtures.changed(PersonalControlFixtures.currentBed()) {
            var scope = try XCTUnwrap($0["scope"] as? [String: Any]); scope["podId"] = session.podId; scope["householdId"] = session.householdId
            scope["sleeperId"] = session.selfSleeperId; scope["sessionRevision"] = session.sessionRevision; scope["assignmentRevision"] = session.assignmentRevision; $0["scope"] = scope
        }
        let controls = PersonalTestServer(bed: bed, session: session), vault = ArrangementTestVault(session), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, personalClient: { _ in controls }, historyClient: { _ in history }, capability: { false }, ownerEndpoint: { nil })
        parent.enter(); await parent.refresh(); let temperature = try XCTUnwrap(parent.temperature), recordings = try XCTUnwrap(parent.history)
        await temperature.refresh(); await history.hold("page")
        let reading = Task { await recordings.refresh() }; await history.waitHeld()
        await temperature.submit(.init(kind: "power", powered: false))
        let posts = await controls.posts; XCTAssertEqual(posts.count, 1)
        let command = try JSONDecoder().decode(PersonalControlRequest.self, from: XCTUnwrap(posts.first))
        XCTAssertEqual(command.action.powered, false)
        await history.release(); await reading.value
    }
}
