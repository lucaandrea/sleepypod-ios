import XCTest
@testable import Sleepypod

@MainActor final class ControllerUpdateTests: XCTestCase {
    private func fixture(client: UpdateMemoryClient = .init(), journal: ControllerUpdateJournal = .init(directory: nil), clock: UpdateTestClock = .init()) -> ControllerUpdateWorkspace {
        .init(client: client, journal: journal, now: { clock.date })
    }
    func testReviewAndTemporaryInternetConsentDoNotChangeNetworking() async throws {
        let client = UpdateMemoryClient(); let workspace = fixture(client: client)
        await workspace.refresh(); await workspace.prepareReview()
        let review = try XCTUnwrap(workspace.review)
        await workspace.start(review, allowTemporaryInternet: false)
        let calls = await client.counts()
        XCTAssertEqual(calls.updates, 0); XCTAssertEqual(calls.blocks, 0)
        XCTAssertNil(workspace.attempt); XCTAssertNotNil(workspace.error)
    }
    func testChangedBaselineOrMissingPinnedRepositoryRefusesDispatch() async throws {
        let client = UpdateMemoryClient(); let workspace = fixture(client: client)
        await workspace.refresh(); await workspace.prepareReview()
        let review = try XCTUnwrap(workspace.review)
        await client.changeBuild(); await workspace.start(review, allowTemporaryInternet: true)
        XCTAssertNil(workspace.attempt); XCTAssertNil(workspace.review)
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 0)
        await client.support(false); await workspace.prepareReview()
        XCTAssertNil(workspace.review); XCTAssertTrue(workspace.error?.contains("installed-repository") == true)
    }
    func testExpiredReviewCannotSend() async throws {
        let clock = UpdateTestClock(); let client = UpdateMemoryClient(); let workspace = fixture(client: client, clock: clock)
        await workspace.refresh(); await workspace.prepareReview()
        let review = try XCTUnwrap(workspace.review); clock.date.addTimeInterval(301)
        await workspace.start(review, allowTemporaryInternet: true)
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 0)
        XCTAssertNil(workspace.attempt)
    }
    func testLostReplySurvivesReopeningAndNeverRepeatsUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = UpdateMemoryClient(); await client.loseReceipt()
        let workspace = fixture(client: client, journal: .init(directory: directory))
        await workspace.refresh(); await workspace.prepareReview()
        await workspace.start(try XCTUnwrap(workspace.review), allowTemporaryInternet: true)
        XCTAssertNotNil(workspace.attempt?.dispatchError)
        let original = try XCTUnwrap(workspace.attempt)
        let reopened = fixture(client: client, journal: .init(directory: directory))
        XCTAssertEqual(reopened.attempt, original)
        await reopened.refresh(); await reopened.prepareReview()
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 1); XCTAssertEqual(counts.blocks, 0)
        XCTAssertNil(reopened.review); XCTAssertEqual(reopened.attempt?.id, original.id)
    }
    func testPersistenceFailureHappensBeforeAnyUpdate() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        let client = UpdateMemoryClient(); let workspace = fixture(client: client, journal: .init(directory: path))
        await workspace.refresh(); await workspace.prepareReview()
        await workspace.start(try XCTUnwrap(workspace.review), allowTemporaryInternet: true)
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 0); XCTAssertNil(workspace.attempt)
    }
    func testUnchangedBuildAndConnectionGapAreNotUpdateSuccess() async throws {
        let client = UpdateMemoryClient(); let clock = UpdateTestClock(); let workspace = fixture(client: client, clock: clock)
        await workspace.refresh(); await workspace.prepareReview()
        await workspace.start(try XCTUnwrap(workspace.review), allowTemporaryInternet: true)
        await workspace.observe(); XCTAssertEqual(workspace.attempt?.outcome, .observing)
        await client.failNextVersion(); await workspace.observe()
        XCTAssertEqual(workspace.attempt?.sawConnectionGap, true)
        await workspace.observe(); XCTAssertEqual(workspace.attempt?.outcome, .observing)
        XCTAssertEqual(workspace.attempt?.title, "Connection resumed · build unchanged")
        clock.date.addTimeInterval(181); await workspace.observe()
        XCTAssertEqual(workspace.attempt?.outcome, .unconfirmed)
        await client.changeBuild(); await workspace.observe()
        XCTAssertEqual(workspace.attempt?.outcome, .changedBuild)
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 1)
    }
    func testWrongChannelChangeDoesNotCompleteRequestedChannel() async throws {
        let client = UpdateMemoryClient(); let workspace = fixture(client: client)
        await workspace.refresh(); await workspace.prepareReview()
        await workspace.start(try XCTUnwrap(workspace.review), allowTemporaryInternet: true)
        await client.changeBuild(branch: "different"); await workspace.observe()
        XCTAssertEqual(workspace.attempt?.outcome, .observing)
    }
    func testRestoreReadsBeforeRepeatingUnknownNetworkRequest() async throws {
        let client = UpdateMemoryClient(); let workspace = fixture(client: client)
        await workspace.refresh(); await workspace.prepareReview()
        await workspace.start(try XCTUnwrap(workspace.review), allowTemporaryInternet: true)
        await client.changeBuild(); await client.setBlocked(false); await workspace.observe()
        XCTAssertEqual(workspace.attempt?.needsNetworkRestore, true)
        await client.loseBlockReply(); await workspace.restoreLocalOnly()
        XCTAssertNotNil(workspace.attempt?.restoreError)
        await workspace.restoreLocalOnly()
        XCTAssertEqual(workspace.attempt?.networkBlocked, true)
        let counts = await client.counts(); XCTAssertEqual(counts.blocks, 1)
        workspace.finishReview(); XCTAssertNil(workspace.attempt)
    }
    func testUnreadableRecordRequiresExplicitRecoveryAndPreservesReadableRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ControllerUpdateJournal(directory: directory); let client = UpdateMemoryClient()
        let workspace = fixture(client: client, journal: journal)
        await workspace.refresh(); await workspace.prepareReview()
        await workspace.start(try XCTUnwrap(workspace.review), allowTemporaryInternet: true)
        XCTAssertThrowsError(try journal.discardUnreadable(scope: client.scope))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("incomplete".utf8).write(to: file)
        let reopened = fixture(client: client, journal: journal)
        XCTAssertTrue(reopened.storageError); XCTAssertFalse(reopened.canReview)
        await reopened.refresh(); XCTAssertNil(reopened.snapshot)
        reopened.discardUnreadableRecord()
        XCTAssertFalse(reopened.storageError); XCTAssertNil(try journal.read(scope: client.scope))
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 1)
    }
    func testMalformedReceiptRetainsUnknownAttemptWithoutReplay() async throws {
        let client = UpdateMemoryClient(); await client.returnMalformedReceipt()
        let workspace = fixture(client: client)
        await workspace.refresh(); await workspace.prepareReview()
        await workspace.start(try XCTUnwrap(workspace.review), allowTemporaryInternet: true)
        XCTAssertNil(workspace.attempt?.receipt); XCTAssertNotNil(workspace.attempt?.dispatchError)
        await workspace.refresh(); await workspace.prepareReview()
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 1)
    }
    func testCompetingJournalCannotDispatchOrEraseAnotherAttempt() async throws {
        let journal = ControllerUpdateJournal(directory: nil); let client = UpdateMemoryClient()
        let first = fixture(client: client, journal: journal); let second = fixture(client: client, journal: journal)
        await first.refresh(); await first.prepareReview(); await second.refresh(); await second.prepareReview()
        let secondReview = try XCTUnwrap(second.review)
        await first.start(try XCTUnwrap(first.review), allowTemporaryInternet: true)
        await second.start(secondReview, allowTemporaryInternet: true)
        let counts = await client.counts(); XCTAssertEqual(counts.updates, 1)
        XCTAssertNil(second.attempt); XCTAssertNotNil(second.error)
        XCTAssertNotNil(try journal.read(scope: client.scope))
    }
}

@MainActor private final class UpdateTestClock {
    var date = Date(timeIntervalSince1970: 1800000000)
}
private actor UpdateMemoryClient: ControllerUpdateServing {
    nonisolated let scope = "synthetic-update-tests"
    private var build = ControllerBuild(branch: "main", commitHash: "baseline", commitTitle: "Synthetic", buildDate: "2026-10-25T00:00:00Z", version: nil)
    private var blocked = true
    private var supported = true
    private var malformedReceipt = false
    private var missingReceipt = false
    private var missingBlockReply = false
    private var badRead = false
    private var updateCalls = 0
    private var blockCalls = 0
    func counts() -> (updates: Int, blocks: Int) { (updateCalls, blockCalls) }
    func support(_ value: Bool) { supported = value }
    func changeBuild(branch: String = "main") { build = .init(branch: branch, commitHash: "changed", commitTitle: "Synthetic changed", buildDate: "2026-10-26T00:00:00Z", version: nil) }
    func setBlocked(_ value: Bool) { blocked = value }
    func returnMalformedReceipt() { malformedReceipt = true }
    func loseReceipt() { missingReceipt = true }
    func loseBlockReply() { missingBlockReply = true }
    func failNextVersion() { badRead = true }
    func snapshot() -> ControllerUpdateSnapshot { .init(build: build, internetBlocked: blocked, preservesInstalledRepository: supported) }
    func version() throws -> ControllerBuild {
        if badRead { badRead = false; throw APIError.serverError(message: "Synthetic connection loss") }
        return build
    }
    func internetBlocked() -> Bool { blocked }
    func trigger(channel: ControllerUpdateChannel) throws -> ControllerUpdateReceipt {
        updateCalls += 1
        if missingReceipt { throw APIError.serverError(message: "Synthetic lost response") }
        return .init(triggered: !malformedReceipt, branch: channel.rawValue, repository: "synthetic/repo", message: "Synthetic dispatch")
    }
    func blockInternet() throws -> Bool {
        blockCalls += 1; blocked = true
        if missingBlockReply { throw APIError.serverError(message: "Synthetic lost response") }
        return blocked
    }
}
