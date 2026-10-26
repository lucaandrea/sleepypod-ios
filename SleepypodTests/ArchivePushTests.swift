import XCTest
@testable import Sleepypod

@MainActor final class ArchivePushTests: XCTestCase {
    func testDraftPreservesIdentityAndRejectsInvalidPortOrEmptyDatasets() async throws {
        let config = await DemoArchivePushClient().settings().config
        var draft = ArchivePushDraft(config)
        draft.host = "nas.example.invalid"; draft.port = "65536"
        XCTAssertNil(draft.configuration)
        draft.port = "2222"; draft.includeRaw = false; draft.includeDatabase = false
        XCTAssertNil(draft.configuration)
        draft.includeDatabase = true
        XCTAssertEqual(draft.configuration?.identity, config.identity)
        XCTAssertEqual(draft.configuration?.include, ["db"])
        draft.enabled = true; draft.remoteUser = ""
        XCTAssertNotNil(draft.issue)
        draft.remoteUser = "user\nname"
        XCTAssertNotNil(draft.issue)
    }
    func testReadFailureDoesNotInventEditableDefaults() async {
        let model = ArchivePushWorkspace(client: ArchiveFixtureClient(failReads: true))
        await model.refresh()
        XCTAssertNil(model.snapshot); XCTAssertNil(model.draft); XCTAssertNotNil(model.error)
    }
    func testConflictPreventsReplacingDestinationAndRetainsDraft() async {
        let client = ArchiveFixtureClient(), model = ArchivePushWorkspace(client: client)
        await model.refresh(); model.draft?.remotePath = "/owner/local-edit"
        await client.changeHost()
        await model.save()
        let writes = await client.writes
        XCTAssertEqual(writes, 0); XCTAssertTrue(model.mustReload)
        XCTAssertEqual(model.draft?.remotePath, "/owner/local-edit")
    }
    func testUnknownWriteNeedsReadbackAndDoesNotAutomaticallyRetry() async {
        let client = ArchiveFixtureClient(failWrites: true), model = ArchivePushWorkspace(client: client)
        await model.refresh(); model.draft?.remotePath = "/owner/new-path"
        await model.save(); await model.save()
        let writes = await client.writes
        XCTAssertEqual(writes, 1); XCTAssertTrue(model.mustReload); XCTAssertNil(model.receipt)
        XCTAssertEqual(model.draft?.remotePath, "/owner/new-path")
        await model.refresh(discardDraft: true)
        XCTAssertFalse(model.mustReload); XCTAssertFalse(model.dirty)
    }
    func testAcknowledgedSaveIsDistinctFromFailedReadback() async {
        let client = ArchiveFixtureClient(failReadback: true), model = ArchivePushWorkspace(client: client)
        await model.refresh(); model.draft?.remotePath = "/owner/new-path"
        await model.save()
        XCTAssertTrue(model.receipt?.contains("configuration saved") == true)
        XCTAssertTrue(model.error?.contains("acknowledged") == true); XCTAssertTrue(model.mustReload)
    }
    func testConnectionUsesSavedDestinationAndReceiptDoesNotFollowEdits() async {
        let client = ArchiveFixtureClient(), model = ArchivePushWorkspace(client: client)
        await model.refresh(); model.draft?.host = "changed.example.invalid"
        await model.testConnection()
        let beforeSave = await client.tests
        XCTAssertEqual(beforeSave, 0)
        await model.save(); await model.testConnection()
        let afterSave = await client.tests
        XCTAssertEqual(afterSave, 1); XCTAssertEqual(model.currentTest?.ok, true)
        model.draft?.port = "2222"
        XCTAssertNil(model.currentTest)
    }
    func testRemoteDestinationChangeBlocksTestBeforeContact() async {
        let client = ArchiveFixtureClient(), model = ArchivePushWorkspace(client: client)
        await model.refresh(); await client.changeHost(); await model.testConnection()
        let tests = await client.tests
        XCTAssertEqual(tests, 0); XCTAssertTrue(model.mustReload)
    }
    func testKeyGenerationRefreshesPublicKeyWithoutChangingConfiguration() async {
        let model = ArchivePushWorkspace(client: DemoArchivePushClient())
        await model.refresh()
        let original = model.snapshot?.config
        await model.generateKey()
        XCTAssertNotNil(model.snapshot?.publicKey)
        XCTAssertEqual(model.snapshot?.config, original)
        XCTAssertFalse(model.dirty); XCTAssertNotNil(model.receipt)
    }
}

private actor ArchiveFixtureClient: ArchivePushClient {
    private let demo = DemoArchivePushClient()
    private let failReads: Bool
    private let failWrites: Bool
    private let failReadback: Bool
    private(set) var writes = 0
    private(set) var tests = 0
    init(failReads: Bool = false, failWrites: Bool = false, failReadback: Bool = false) {
        self.failReads = failReads; self.failWrites = failWrites; self.failReadback = failReadback
    }
    func changeHost() async {
        var config = await demo.settings().config
        config.host = "remote-edit.example.invalid"
        await demo.save(config)
    }
    func settings() async throws -> ArchivePushSnapshot {
        if failReads || (failReadback && writes > 0) { throw APIError.noBaseURL }
        return await demo.settings()
    }
    func save(_ config: ArchivePushConfiguration) async throws {
        writes += 1
        if failWrites { throw APIError.noBaseURL }
        await demo.save(config)
    }
    func generateKey() async throws -> ArchivePushKeyReceipt { await demo.generateKey() }
    func test() async throws -> ArchivePushTestReceipt { tests += 1; return await demo.test() }
}
