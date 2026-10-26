import XCTest
@testable import Sleepypod

@MainActor final class PersonalComfortTests: XCTestCase {
    private func example() throws -> PersonalComfortExample { try PersonalComfortExample.load() }
    func testConfigOnlyAllowsPreviewOrOffAndValidGuardedRanges() throws {
        var config = try example().status.state!.config
        for mode in ["off", "preview"] { config.mode = mode; XCTAssertNoThrow(try config.validate()) }
        config.mode = "active"; XCTAssertThrowsError(try config.validate()); XCTAssertEqual(config.editable.mode, "off")
        config.mode = "preview"; config.minimumF = 90; config.maximumF = 65; XCTAssertThrowsError(try config.validate())
        config.minimumF = 55; config.maximumF = 110; config.followBedtime = true; config.sensorAware = false; XCTAssertThrowsError(try config.validate())
        config.sensorAware = true; XCTAssertNoThrow(try config.validate())
        config.maximumF = 111; XCTAssertThrowsError(try config.validate())
    }
    func testFeedbackUsesPodCalendarDatesAcrossMonthAndDSTBoundaries() throws {
        let dates = PersonalComfortDates.feedbackDates(through: "2026-11-02")
        XCTAssertEqual(dates.count, 15); XCTAssertEqual(dates.first, "2026-11-02"); XCTAssertEqual(dates.last, "2026-10-19")
        XCTAssertNoThrow(try PersonalComfortFeedback(date: "2026-10-19", comfort: "warm").validate(deviceDate: "2026-11-02"))
        for day in ["2026-11-03", "2026-10-18", "2026-02-30", "2026-1-2"] {
            XCTAssertThrowsError(try PersonalComfortFeedback(date: day, comfort: "comfortable").validate(deviceDate: "2026-11-02"))
        }
        XCTAssertNil(PersonalComfortDates.date("2026-02-30"))
        XCTAssertThrowsError(try PersonalComfortFeedback(date: "2026-11-02", comfort: "hot").validate(deviceDate: "2026-11-02"))
    }
    func testDemoNeverCountsSyntheticReportsAndStartsWithoutReports() async throws {
        let empty = try await DemoPersonalComfortClient().reports(side: .left); XCTAssertTrue(empty.items.isEmpty)
        let client = DemoPersonalComfortClient(includeExample: true), fixture = try example()
        let reports = try await client.reports(side: .right); try reports.validate(side: .right)
        XCTAssertEqual(reports.ownerConfirmedNights, 0); XCTAssertFalse(reports.activationAvailable); XCTAssertFalse(reports.items[0].summary.reviewable)
        let detail = try await client.report(side: .right, id: fixture.report.summary.id, after: nil)
        var review = ComfortReviewInput(side: .right, report: detail); review.outcome = "reviewed"; review.confirmedActualNight = true
        do { _ = try await client.review(review); XCTFail("Synthetic review was accepted") } catch { }
        review.outcome = "needs_retest"; review.confirmedActualNight = false; _ = try await client.review(review)
        let after = try await client.reports(side: .right); XCTAssertEqual(after.ownerConfirmedNights, 0); XCTAssertFalse(after.items[0].countsAsOwnerConfirmedNight)
    }
    func testDemoCheckInRemainsSideScopedAndDoesNotInventLearning() async throws {
        let client = DemoPersonalComfortClient()
        _ = try await client.feedback(side: .left, input: .init(date: "2026-10-25", comfort: "warm"))
        let left = try await client.status(side: .left), right = try await client.status(side: .right)
        XCTAssertEqual(left.state?.feedbackThrough, "2026-10-25"); XCTAssertEqual(left.history.count, 1)
        XCTAssertEqual(left.state?.offsetF, 0); XCTAssertNil(left.evaluatedAt)
        XCTAssertTrue(right.history.isEmpty); XCTAssertEqual(right.state?.feedbackThrough, "")
    }
    func testReviewBindsExactDigestRevisionAndRequiresExplicitActualNight() throws {
        let detail = try example().report
        var input = ComfortReviewInput(side: .left, report: detail)
        XCTAssertNoThrow(try input.validate(report: detail)); XCTAssertFalse(input.confirmedActualNight); XCTAssertEqual(input.outcome, "needs_retest")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
        XCTAssertTrue(encoded.keys.contains("expectedReviewId")); XCTAssertTrue(encoded["expectedReviewId"] is NSNull)
        input.outcome = "reviewed"; XCTAssertThrowsError(try input.validate(report: detail))
        input.confirmedActualNight = true; XCTAssertThrowsError(try input.validate(report: detail))
        let eligible = try replacing(detail, fields: ["summary": ["reviewable": true]])
        XCTAssertNoThrow(try input.validate(report: eligible))
        let changed = try replacing(eligible, fields: ["summary": ["digest": String(repeating: "f", count: 64)]])
        XCTAssertThrowsError(try input.validate(report: changed))
        input.note = String(repeating: "😀", count: 1001); XCTAssertThrowsError(try input.validate(report: eligible))
    }
    func testInvalidIdentityAndUnadvancingReportCursorAreRejected() throws {
        let source = try example().report
        try source.validate(id: source.summary.id)
        XCTAssertThrowsError(try source.validate(id: String(repeating: "c", count: 64)))
        let changed = try replacing(source, fields: ["nextAfterId": 1])
        XCTAssertThrowsError(try changed.validate(id: source.summary.id))
        let status = try example().status
        XCTAssertThrowsError(try status.validate(side: .right))
        XCTAssertThrowsError(try replacing(status, fields: ["activation": ["available": true]]).validate(side: .left))
    }
    func testChangedConfigurationPreventsUnsentWrite() async throws {
        let source = try example().status, client = ComfortTestClient(source: source, detail: try example().report), model = PersonalComfortWorkspace()
        model.configure(client: client, side: .left); await model.load()
        var draft = source.state!.config; draft.mode = "preview"
        try await client.changeConfiguration(draft)
        let result = await model.save(draft, original: source.state!.config), writes = await client.configurationWrites
        XCTAssertFalse(result); XCTAssertEqual(writes, 0); XCTAssertNil(model.status); XCTAssertNotNil(model.error)
    }
    func testUnknownWriteRequiresReloadAndDoesNotReplay() async throws {
        let source = try example().status, client = ComfortTestClient(source: source, detail: try example().report), model = PersonalComfortWorkspace()
        model.configure(client: client, side: .left); await model.load(); await client.failConfigurationResponse()
        var draft = source.state!.config; draft.mode = "preview"
        let first = await model.save(draft, original: source.state!.config), second = await model.save(draft, original: source.state!.config)
        let writes = await client.configurationWrites
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertEqual(writes, 1); XCTAssertNil(model.status)
        await model.load(); XCTAssertNil(model.status)
        await model.load(userInitiated: true); XCTAssertEqual(model.status?.state?.config, draft)
    }
    func testControllerInvalidationDuringPreflightPreventsDispatch() async throws {
        let source = try example().status, client = ComfortTestClient(source: source, detail: try example().report), model = PersonalComfortWorkspace()
        model.configure(client: client, side: .left); await model.load(); await client.holdStatus()
        var draft = source.state!.config; draft.mode = "preview"
        let pending = Task { await model.save(draft, original: source.state!.config) }
        await client.waitForStatus(); model.invalidate(); await client.releaseStatus()
        let result = await pending.value, writes = await client.configurationWrites
        XCTAssertFalse(result); XCTAssertEqual(writes, 0); XCTAssertNil(model.status); XCTAssertFalse(model.saving)
    }
    func testChangedPageDigestDropsOldObservationsAndReview() async throws {
        let fixture = try example(), client = ComfortTestClient(source: fixture.status, detail: fixture.report)
        let model = ComfortNightWorkspace(client: client, side: .left, id: fixture.report.summary.id)
        await model.load(); XCTAssertNotNil(model.detail)
        try await client.changeReportDigest()
        await model.load(after: 2)
        XCTAssertNil(model.detail); XCTAssertNil(model.after); XCTAssertTrue(model.error?.contains("changed while paging") == true)
        await model.load(); XCTAssertNotNil(model.detail); XCTAssertNil(model.error)
    }
    func testUnknownReviewOutcomeNeverRepeatsAutomatically() async throws {
        let fixture = try example(), client = ComfortTestClient(source: fixture.status, detail: fixture.report)
        let model = ComfortNightWorkspace(client: client, side: .left, id: fixture.report.summary.id)
        await model.load(); let input = ComfortReviewInput(side: .left, report: try XCTUnwrap(model.detail))
        await client.failReviewResponse()
        let first = await model.save(input), second = await model.save(input), writes = await client.reviewWrites
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertEqual(writes, 1); XCTAssertNil(model.detail)
    }
}

private func replacing<Value: Codable>(_ value: Value, fields: [String: Any]) throws -> Value {
    var source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    for (key, replacement) in fields {
        if let update = replacement as? [String: Any], var existing = source[key] as? [String: Any] { existing.merge(update) { _, new in new }; source[key] = existing }
        else { source[key] = replacement }
    }
    return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: source))
}
private actor ComfortTestClient: PersonalComfortClient {
    var source: PersonalComfortStatus
    var detail: ComfortNightDetail
    var configurationWrites = 0
    var reviewWrites = 0
    private var failConfiguration = false
    private var failReview = false
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(source: PersonalComfortStatus, detail: ComfortNightDetail) { self.source = source; self.detail = detail }
    func changeConfiguration(_ config: PersonalComfortConfig) throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        source = try replacing(source, fields: ["state": ["config": encoded]])
    }
    func changeReportDigest() throws { detail = try replacing(detail, fields: ["summary": ["digest": String(repeating: "f", count: 64)]]) }
    func failConfigurationResponse() { failConfiguration = true }
    func failReviewResponse() { failReview = true }
    func holdStatus() { hold = true }
    func waitForStatus() async { if continuation == nil { await withCheckedContinuation { observer = $0 } } }
    func releaseStatus() { continuation?.resume(); continuation = nil }
    func status(side: Side) async -> PersonalComfortStatus {
        if hold { hold = false; await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil } }
        return source
    }
    func configure(side: Side, config: PersonalComfortConfig) throws -> PersonalComfortStatus {
        configurationWrites += 1; try changeConfiguration(config)
        if failConfiguration { throw URLError(.timedOut) }; return source
    }
    func feedback(side: Side, input: PersonalComfortFeedback) -> PersonalComfortStatus { source }
    func reports(side: Side) -> ComfortNightList { .init(apiVersion: 1, generatedAt: source.generatedAt, side: side, items: [detail.item], targetNights: 7, ownerConfirmedNights: 0, activationAvailable: false) }
    func report(side: Side, id: String, after: Int?) -> ComfortNightDetail {
        .init(summary: detail.summary, review: detail.review, reviewCurrent: detail.reviewCurrent, countsAsOwnerConfirmedNight: false,
              observations: detail.observations.filter { $0.id > (after ?? 0) }, nextAfterId: nil)
    }
    func review(_ input: ComfortReviewInput) throws -> ComfortNightReview {
        reviewWrites += 1
        if failReview { throw URLError(.timedOut) }
        return .init(id: reviewWrites, at: source.generatedAt, digest: input.digest, outcome: input.outcome, confirmedActualNight: input.confirmedActualNight, note: input.note)
    }
}
