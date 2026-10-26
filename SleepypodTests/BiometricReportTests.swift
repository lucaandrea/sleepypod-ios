import XCTest
@testable import Sleepypod

@MainActor final class BiometricReportTests: XCTestCase {
    func testLiteralCoreReportsKeepSummaryAndJobIdentities() throws {
        let examples = try BiometricReportExample.load()
        XCTAssertEqual(examples.count, 3)
        for example in examples {
            try example.summary.validate(job: example.job)
            let header = try example.summary.decoded(BiometricEvaluationReport.self)
            try header.validate(job: example.job, side: .left, projection: example.summary.projection)
            XCTAssertEqual(header.status, .insufficient)
            XCTAssertTrue(header.limitations.contains { $0.contains("Synthetic example") })
            let numeric = try example.summary.decoded(BiometricNumericReport.self)
            try numeric.validate(job: example.job)
            XCTAssertEqual(numeric.nights.count, 1)
            if header.hasStages { try example.summary.decoded(BiometricStageReport.self).validate(job: example.job) }
            XCTAssertEqual(example.summary.contentHashScope, "complete_retained_report")
        }
    }
    func testThreeMetricCoreReportRetainsAllThirtySixSubgroups() throws {
        struct Example: Decodable { let job: BiometricBacktestJob; let summary: BiometricReportDescriptor }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "backtest-three-metric-report", withExtension: "json"))
        let example = try JSONDecoder().decode(Example.self, from: Data(contentsOf: url))
        try example.summary.validate(job: example.job)
        try example.summary.decoded(BiometricEvaluationReport.self).validate(job: example.job, side: .left, projection: example.summary.projection)
        let numeric = try example.summary.decoded(BiometricNumericReport.self)
        try numeric.validate(job: example.job)
        XCTAssertEqual(numeric.numericSubgroupSummary?.count, 36)
        for metric in BiometricReportMetric.allCases {
            XCTAssertEqual(numeric.numericSubgroupSummary?.filter { $0.summary.metric == metric }.count, 12)
        }
        var json = try JSONValue.encoded(numeric)
        let groups = try XCTUnwrap(numeric.numericSubgroupSummary)
        json = try json.replacing(at: "numericSubgroupSummary", with: JSONValue.encoded(groups + [groups[0]]))
        let oversized = try JSONDecoder().decode(BiometricNumericReport.self, from: JSONEncoder().encode(json))
        XCTAssertThrowsError(try oversized.validate(job: example.job))
    }
    func testExactCoreTracePagesValidateConfigurationSideAndCursor() throws {
        for example in try BiometricReportExample.load() {
            for page in example.stagePages {
                let selection = BiometricTraceSelection(jobId: example.id, contentHash: example.summary.contentHash, configuration: page.configuration, cohortId: "night", offset: page.offset, limit: page.limit)
                try page.validate(selection, job: example.job)
                var incorrect = selection; incorrect.offset += 1
                XCTAssertThrowsError(try page.validate(incorrect, job: example.job))
            }
            for page in example.numericPages {
                let selection = BiometricTraceSelection(jobId: example.id, contentHash: example.summary.contentHash, configuration: page.configuration, cohortId: "night", offset: page.offset, limit: page.limit)
                try page.validate(selection, job: example.job, side: .left)
                XCTAssertThrowsError(try page.validate(selection, job: example.job, side: .right))
            }
            for page in example.referencePages {
                let selection = BiometricTraceSelection(jobId: example.id, contentHash: example.summary.contentHash, cohortId: "night", offset: page.offset, limit: page.limit)
                try page.validate(selection, metric: page.metric, job: example.job, side: .left, clockOffset: page.clockOffsetMs)
                XCTAssertThrowsError(try page.validate(selection, metric: page.metric, job: example.job, side: .left, clockOffset: page.clockOffsetMs + 1))
            }
        }
    }
    func testUnknownVersionSideAndFrozenHashesCannotBeAccepted() throws {
        let example = try sample()
        let header = try example.summary.decoded(BiometricEvaluationReport.self)
        XCTAssertThrowsError(try header.validate(job: example.job, side: .right, projection: example.summary.projection))
        XCTAssertThrowsError(try header.validate(job: example.job, side: .left, projection: "scores_without_replay_trace_rows_v1"))
        for (path, value) in [("version", "future-report-v2"), ("datasetHash", String(repeating: "0", count: 64)), ("evaluatorBuildHash", String(repeating: "1", count: 64))] {
            let changed = try JSONValue.encoded(header).replacing(at: path, with: .string(value))
            let decoded = try JSONDecoder().decode(BiometricEvaluationReport.self, from: JSONEncoder().encode(changed))
            XCTAssertThrowsError(try decoded.validate(job: example.job, side: .left, projection: example.summary.projection))
        }
    }
    func testMissingAndReleasedReportsAreDistinctAndExamplesCannotBecomeQueuedResults() async throws {
        let client = DemoBiometricReportsClient(), example = try sample()
        let missing = try await client.summary(id: UUID().uuidString)
        XCTAssertNil(missing)
        let initialRead = try await client.summary(id: example.id)
        let before = try XCTUnwrap(initialRead)
        XCTAssertTrue(before.available)
        let releaseRead = try await client.release(id: example.id, expectedHash: before.contentHash)
        let receipt = try XCTUnwrap(releaseRead)
        XCTAssertTrue(receipt.confirms(id: example.id, hash: before.contentHash))
        let releasedRead = try await client.summary(id: example.id)
        let after = try XCTUnwrap(releasedRead)
        try after.validate(job: example.job)
        XCTAssertFalse(after.available); XCTAssertNil(after.report)
        let again = try await client.release(id: example.id, expectedHash: before.contentHash)
        XCTAssertEqual(again?.releasedAtMs, receipt.releasedAtMs)
        do { _ = try await client.release(id: example.id, expectedHash: String(repeating: "0", count: 64)); XCTFail("Changed hash") } catch {}
    }
    func testExampleTracePaginationUsesOnlyFrozenRowsAndRejectsReleasedOrWrongNight() async throws {
        let example = try sample("signal_replay"), client = DemoBiometricReportsClient()
        var selection = BiometricTraceSelection(jobId: example.id, contentHash: example.summary.contentHash, cohortId: "night", limit: 4)
        let first = try await client.numeric(selection)
        try first.validate(selection, job: example.job, side: .left)
        XCTAssertEqual(first.items.count, 4); XCTAssertEqual(first.nextCursor?.offset, 4)
        selection.offset = 4
        let next = try await client.numeric(selection)
        XCTAssertEqual(next.items.first?.timestampMs, example.numericPages.filter { $0.configuration == .candidate }.flatMap(\.items)[4].timestampMs)
        selection.cohortId = "missing"
        do { _ = try await client.numeric(selection); XCTFail("Unknown night") } catch {}
        _ = try await client.release(id: example.id, expectedHash: example.summary.contentHash)
        selection.cohortId = "night"
        do { _ = try await client.numeric(selection); XCTFail("Released report") } catch {}
    }
    func testFailedReadPreservesReportAndLatePollCannotUndoRelease() async throws {
        let example = try sample(), client = ControlledReportsClient()
        let model = BiometricReportWorkspace(job: example.job, side: .left, client: client)
        await model.load(); XCTAssertNotNil(model.report)
        await client.failNext(); await model.load()
        XCTAssertNotNil(model.report); XCTAssertNotNil(model.error)
        await client.suspendNext()
        let polling = Task { await model.load() }
        await client.waitForPendingRead()
        let receipt = BiometricReportReleaseReceipt(jobId: example.id, contentHash: example.summary.contentHash, available: false, releasedAtMs: 1792999800000)
        model.acceptRelease(receipt)
        await client.complete(with: example.summary); await polling.value
        XCTAssertNil(model.report); XCTAssertNil(model.numeric); XCTAssertFalse(model.descriptor?.available ?? true)
    }
    func testUnknownReleaseSurvivesReopeningAndReadbackDoesNotRepeatIt() async throws {
        let example = try sample(), reports = ControlledReportsClient(), store = BiometricBacktestPendingStore(directory: nil)
        let client = DemoBiometricDatasetsClient(reports: reports)
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await reports.loseNextRelease()
        await model.releaseReport(job: example.job, descriptor: example.summary)
        XCTAssertNotNil(model.pending); XCTAssertNil(model.reportReceipt)
        let reopened = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        let before = await reports.releaseCount(); XCTAssertEqual(before, 1)
        await reopened.inspectReportRelease()
        let after = await reports.releaseCount(); XCTAssertEqual(after, 1)
        XCTAssertNil(reopened.pending)
        XCTAssertTrue(reopened.reportReceipt?.confirms(id: example.id, hash: example.summary.contentHash) == true)
        await model.retry()
        let stale = await reports.releaseCount(); XCTAssertEqual(stale, 1)
        XCTAssertTrue(model.error?.contains("removed or replaced") == true)
    }
    func testMissingReadbackCannotConfirmUnknownReportRelease() async throws {
        let example = try sample(), reports = ControlledReportsClient(), store = BiometricBacktestPendingStore(directory: nil)
        let client = DemoBiometricDatasetsClient(reports: reports)
        let model = BiometricDatasetWorkspace(side: .left, client: client, store: store)
        await reports.loseNextRelease(); await model.releaseReport(job: example.job, descriptor: example.summary)
        await reports.hideReleasedSummary(); await model.retry()
        XCTAssertNotNil(model.pending); XCTAssertNil(model.reportReceipt)
        let attempts = await reports.releaseCount(); XCTAssertEqual(attempts, 1)
        XCTAssertTrue(model.error?.contains("unconfirmed") == true)
    }
    func testLateTraceResponseCannotReplaceNewConfiguration() async throws {
        let example = try sample("signal_replay"), client = ControlledReportsClient()
        let numeric = try example.summary.decoded(BiometricNumericReport.self)
        let model = BiometricTraceWorkspace(job: example.job, side: .left, hash: example.summary.contentHash, kind: .stages, nights: numeric.nights, client: client)
        await client.holdNextStage()
        let old = Task { await model.load() }
        await client.waitForStage()
        await model.chooseConfiguration(.candidate)
        XCTAssertEqual(model.stagePage?.configuration, .candidate)
        await client.finishStage(); await old.value
        XCTAssertEqual(model.selection.configuration, .candidate)
        XCTAssertEqual(model.stagePage?.configuration, .candidate)
    }
    func testEmptyNightOrConfigurationHasNoTraceRequest() async throws {
        let example = try sample(), client = ControlledReportsClient()
        let model = BiometricTraceWorkspace(job: example.job, side: .left, hash: example.summary.contentHash, kind: .stages,
                                           nights: [.init(cohortId: "empty", numericComparisons: nil, evaluations: [])], client: client)
        await model.load()
        XCTAssertNil(model.error); XCTAssertNil(model.stagePage); XCTAssertFalse(model.loading)
        XCTAssertTrue(model.configurations.isEmpty)
        let empty = BiometricTraceWorkspace(job: example.job, side: .left, hash: example.summary.contentHash, kind: .numeric, nights: [], client: client)
        await empty.load()
        XCTAssertNil(empty.error); XCTAssertNil(empty.numericPage)
    }
    private func sample(_ name: String = "comparison") throws -> BiometricReportExample {
        try XCTUnwrap(BiometricReportExample.load().first { $0.name == name })
    }
}

private actor ControlledReportsClient: BiometricReportsServing {
    private let demo = DemoBiometricReportsClient()
    private var failure = false
    private var releases = 0
    private var loseRelease = false
    private var hideSummary = false
    private var holdStage = false
    private var stagePending: CheckedContinuation<Void, Never>?
    private var stageWaiter: CheckedContinuation<Void, Never>?
    func loseNextRelease() { loseRelease = true }
    func hideReleasedSummary() { hideSummary = true }
    func releaseCount() -> Int { releases }
    func holdNextStage() { holdStage = true }
    func waitForStage() async { if stagePending == nil { await withCheckedContinuation { stageWaiter = $0 } } }
    func finishStage() { stagePending?.resume(); stagePending = nil }
    private var shouldSuspend = false
    private var pending: CheckedContinuation<BiometricReportDescriptor?, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func failNext() { failure = true }
    func suspendNext() { shouldSuspend = true }
    func waitForPendingRead() async { if pending == nil { await withCheckedContinuation { waiter = $0 } } }
    func complete(with value: BiometricReportDescriptor) { pending?.resume(returning: value); pending = nil }
    func summary(id: String) async throws -> BiometricReportDescriptor? {
        if hideSummary && releases > 0 { return nil }
        if failure { failure = false; throw BiometricBacktestInput.error("Read failed") }
        if shouldSuspend {
            shouldSuspend = false
            return try await withCheckedThrowingContinuation { pending = $0; waiter?.resume(); waiter = nil }
        }
        return try await demo.summary(id: id)
    }
    func release(id: String, expectedHash: String) async throws -> BiometricReportReleaseReceipt? {
        releases += 1
        let receipt = try await demo.release(id: id, expectedHash: expectedHash)
        if loseRelease { loseRelease = false; throw BiometricBacktestInput.error("Response lost") }
        return receipt
    }
    func stages(_ selection: BiometricTraceSelection) async throws -> BiometricStageTracePage {
        let result = try await demo.stages(selection)
        if holdStage { holdStage = false; await withCheckedContinuation { stagePending = $0; stageWaiter?.resume(); stageWaiter = nil } }
        return result
    }
    func numeric(_ selection: BiometricTraceSelection) async throws -> BiometricNumericTracePage { try await demo.numeric(selection) }
    func references(_ selection: BiometricTraceSelection, metric: BiometricReferenceTraceMetric) async throws -> BiometricReferenceTracePage { try await demo.references(selection, metric: metric) }
}
