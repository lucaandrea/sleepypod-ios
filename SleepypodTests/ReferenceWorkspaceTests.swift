import XCTest
@testable import Sleepypod

@MainActor final class ReferenceWorkspaceTests: XCTestCase {
    func testCoreFixturesKeepDuplicatesRejectionsUnitsAndHRVSemantics() throws {
        let fixture = try ReferenceDemoFixture.load(side: .left)
        XCTAssertEqual(fixture.summary.received, 6); XCTAssertEqual(fixture.summary.accepted, 4)
        XCTAssertEqual(fixture.summary.duplicates, 1); XCTAssertEqual(fixture.summary.rejected, 1)
        XCTAssertEqual(fixture.summary.unscorable, 1)
        let breathing = try XCTUnwrap(fixture.measurements.first { $0.metric == "breathing_rate" })
        XCTAssertEqual(breathing.value, 15); XCTAssertEqual(breathing.unit, "breaths/min")
        let hrv = try XCTUnwrap(fixture.measurements.first { $0.metric == "hrv_unknown" })
        XCTAssertFalse(hrv.scorable); XCTAssertEqual(hrv.exclusions, ["unknown_hrv_definition"])
        XCTAssertEqual(ReferenceLabels.utc(breathing.startMs), "2026-10-24T22:00:00.000Z")
    }
    func testPartialImportRequiresReviewAndEditsInvalidateAcknowledgement() async throws {
        let client = DemoBiometricReferencesClient()
        let draft = ReferenceImportWorkspace(side: .left, client: client)
        draft.loadSample(try .load(side: .left)); draft.subject = " demo-sleeper "; draft.source = " Example watch "; await draft.review()
        XCTAssertNotNil(draft.preview); XCTAssertThrowsError(try draft.request())
        draft.acceptRejected = true
        let request = try draft.request()
        XCTAssertEqual(request.input.rows.count, 6); XCTAssertTrue(request.acceptRejectedRows)
        XCTAssertEqual(request.input.subjectId, "demo-sleeper"); XCTAssertEqual(request.input.source, "Example watch")
        draft.source = "Changed source"
        XCTAssertNil(draft.preview); XCTAssertFalse(draft.acceptRejected); XCTAssertThrowsError(try draft.request())
        let library = await client.library(side: .left, cursor: nil)
        XCTAssertTrue(library.items.isEmpty, "Preview must never save source measurements.")
    }
    func testEditedDraftCannotAcceptAStalePreview() async throws {
        let client = ReferenceScriptedClient(); await client.holdPreview()
        let draft = ReferenceImportWorkspace(side: .left, client: client); draft.loadSample(try .load(side: .left))
        let task = Task { await draft.review() }
        for _ in 0..<100 where !(await client.previewWaiting()) { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await client.previewWaiting(); XCTAssertTrue(waiting)
        draft.subject = "another-sleeper"
        await client.releasePreview(); await task.value
        XCTAssertNil(draft.preview); XCTAssertNil(draft.reviewedInput)
    }
    func testLostCommitIsReconciledWithoutRepeatingWrite() async throws {
        let client = ReferenceScriptedClient(); await client.loseNextCommit()
        let store = ReferencePendingStore(directory: nil)
        let model = BiometricReferencesWorkspace(side: .left, client: client, store: store)
        await model.commit(try request())
        XCTAssertNotNil(model.pending); XCTAssertNil(model.receipt); XCTAssertFalse(model.canRetry)
        let reopened = BiometricReferencesWorkspace(side: .left, client: client, store: store)
        await reopened.inspectPending()
        XCTAssertNil(reopened.pending); XCTAssertNotNil(reopened.receipt)
        let countBeforeRetry = await client.commitCount(); XCTAssertEqual(countBeforeRetry, 1)
        await model.inspectPending()
        XCTAssertFalse(model.canRetry, "The old workspace cannot retry a request cleared elsewhere.")
        await model.retry(); let countAfterRetry = await client.commitCount(); XCTAssertEqual(countAfterRetry, 1)
    }
    func testDeletedMatchingImportCannotBeRecreatedByRetry() async throws {
        let client = ReferenceScriptedClient(); await client.loseNextCommit()
        let model = BiometricReferencesWorkspace(side: .left, client: client, store: .init(directory: nil))
        await model.commit(try request())
        let library = try await client.library(side: .left, cursor: nil)
        let saved = try XCTUnwrap(library.items.first)
        _ = try await client.delete(id: saved.id)
        await model.inspectPending()
        XCTAssertNotNil(model.pending); XCTAssertFalse(model.canRetry)
        XCTAssertTrue(model.error?.contains("deleted") == true)
        await model.retry(); let count = await client.commitCount(); XCTAssertEqual(count, 1)
    }
    func testLostDeleteReplyUsesExactDescriptorReadback() async throws {
        let client = ReferenceScriptedClient()
        let original = try await client.commit(request())
        await client.loseNextDelete()
        let model = BiometricReferencesWorkspace(side: .left, client: client, store: .init(directory: nil))
        await model.delete(original)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.receipt)
        await model.inspectPending()
        XCTAssertNil(model.pending); XCTAssertEqual(model.receipt?.id, original.id); XCTAssertEqual(model.receipt?.available, false)
        let count = await client.deleteCount(); XCTAssertEqual(count, 1)
    }
    func testCorrectionRetainsMappingAndCannotReplaceANewerRevision() async throws {
        let client = DemoBiometricReferencesClient()
        let first = try await client.commit(request())
        let draft = ReferenceImportWorkspace(side: .left, client: client, parent: first)
        draft.loadSample(try .load(side: .left, corrected: true)); await draft.review(); draft.acceptRejected = true
        let second = try await client.commit(draft.request())
        XCTAssertEqual(second.familyId, first.familyId); XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.supersedesImportId, first.id)
        let old = try await client.descriptor(id: first.id)
        XCTAssertEqual(old.summary, first.summary); XCTAssertTrue(old.available)
        draft.subject = "different"; await draft.review(); XCTAssertNil(draft.preview)
        let duplicateParent = try request(parent: first.id)
        do { _ = try await client.commit(duplicateParent); XCTFail("Expected revision conflict") } catch {}
    }
    func testRetainedRowsPersistAndCompetingWorkspaceCannotOverwriteOrRemoveThem() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ReferencePendingStore(directory: folder), first = ReferencePending.commit(try request())
        try store.write(first, scope: "https://one.invalid", side: .left)
        let reopened = ReferencePendingStore(directory: folder)
        XCTAssertEqual(try reopened.read(scope: "https://one.invalid", side: .left), first)
        XCTAssertNil(try reopened.read(scope: "https://two.invalid", side: .left))
        XCTAssertNil(try reopened.read(scope: "https://one.invalid", side: .right))
        let different = ReferencePending.commit(try request(corrected: true))
        XCTAssertThrowsError(try reopened.write(different, scope: "https://one.invalid", side: .left))
        XCTAssertThrowsError(try reopened.remove(different, scope: "https://one.invalid", side: .left))
        XCTAssertEqual(try store.read(scope: "https://one.invalid", side: .left), first)
    }
    func testEnvelopeSizeAndUTF16MappingLimitsAreCheckedBeforeTransport() throws {
        let fixture = try ReferenceDemoFixture.load(side: .left)
        XCTAssertThrowsError(try ReferenceImportInput(side: .left, subjectId: String(repeating: "😀", count: 101), source: "watch", rows: fixture.input.rows).validated())
        let escaped = JSONValue.string(String(repeating: "\n", count: 1_048_576))
        XCTAssertThrowsError(try ReferenceImportInput(side: .left, subjectId: "person", source: "watch", rows: [escaped]).validated())
        XCTAssertThrowsError(try ReferenceImportInput(side: .left, subjectId: "person", source: "watch", rows: [.number(.nan)]).validated())
        var nested = JSONValue.number(1)
        for _ in 0..<14 { nested = .array([nested]) }
        XCTAssertThrowsError(try ReferenceImportInput(side: .left, subjectId: "person", source: "watch", rows: [nested]).validated())
    }
    private func request(corrected: Bool = false, parent: String? = nil) throws -> ReferenceCommit {
        let fixture = try ReferenceDemoFixture.load(side: .left, corrected: corrected)
        return .init(input: fixture.input, previewHash: fixture.summary.contentHash, acceptRejectedRows: true, supersedesImportId: parent)
    }
}

private actor ReferenceScriptedClient: BiometricReferencesServing {
    nonisolated let scope = "reference-lifecycle-tests"
    let base = DemoBiometricReferencesClient()
    private var loseCommit = false, loseDelete = false, commits = 0, deletes = 0, pausePreview = false
    private var continuation: CheckedContinuation<Void, Never>?
    func loseNextCommit() { loseCommit = true }
    func loseNextDelete() { loseDelete = true }
    func holdPreview() { pausePreview = true }
    func previewWaiting() -> Bool { continuation != nil }
    func releasePreview() { continuation?.resume(); continuation = nil; pausePreview = false }
    func commitCount() -> Int { commits }
    func deleteCount() -> Int { deletes }
    func preview(_ input: ReferenceImportInput) async throws -> ReferencePreview {
        let result = try await base.preview(input)
        if pausePreview { await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func commit(_ request: ReferenceCommit) async throws -> ReferenceDescriptor {
        commits += 1; let result = try await base.commit(request)
        if loseCommit { loseCommit = false; throw URLError(.timedOut) }; return result
    }
    func library(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage { await base.library(side: side, cursor: cursor) }
    func descriptor(id: String) async throws -> ReferenceDescriptor { try await base.descriptor(id: id) }
    func measurements(id: String, after: Int) async throws -> ReferenceMeasurementPage { try await base.measurements(id: id, after: after) }
    func delete(id: String) async throws -> ReferenceDeletion {
        deletes += 1; let result = try await base.delete(id: id)
        if loseDelete { loseDelete = false; throw URLError(.timedOut) }; return result
    }
}
