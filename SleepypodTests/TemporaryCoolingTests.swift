import XCTest
@testable import Sleepypod

@MainActor final class TemporaryCoolingTests: XCTestCase {
    func testActualCoreAuthorityStatesDecodeWithoutPhysicalSuccessClaims() throws {
        struct Example: Decodable { let synthetic: Bool; let sourceCommit: String; let cases: [String: TemporaryCooling] }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "temporary-cooling-example", withExtension: "json"))
        let example = try JSONDecoder().decode(Example.self, from: Data(contentsOf: url))
        XCTAssertTrue(example.synthetic); XCTAssertEqual(example.sourceCommit.count, 40)
        XCTAssertEqual(Set(example.cases.keys), ["ready", "active", "waiting", "unknown", "cancelled", "unavailable"])
        for report in example.cases.values { try report.validate(for: report.side); XCTAssertEqual(report.physicalVerification, "unverified") }
        XCTAssertEqual(example.cases["active"]?.lease?.phase, "active")
        XCTAssertEqual(example.cases["unknown"]?.lease?.phase, "unknown")
        XCTAssertNil(example.cases["cancelled"]?.lease)
        XCTAssertEqual(example.cases["cancelled"]?.proposal?.fromTargetF, 70)
        XCTAssertEqual(example.cases["unavailable"]?.side, .right)
    }
    private let now = Date(timeIntervalSince1970: 1_794_350_000)
    private func page(side: Side = .left, offset: Int64 = 0) -> TemporaryCooling {
        let timestamp = Int64(now.timeIntervalSince1970 * 1000) + offset
        return .init(apiVersion: 1, side: side, generatedAt: timestamp, state: "ready", reason: "Synthetic review",
                     observedAt: timestamp, proposal: .init(scope: String(repeating: "a", count: 64), fromTargetF: 70, targetF: 68, expiresAt: timestamp + 1_200_000),
                     lease: nil, physicalVerification: "unverified")
    }
    private func controls(_ client: CoolingCommandFixture, ledger: NativeControlLedger = .init(directory: nil)) -> NativeControlService {
        .init(ledger: ledger, client: { client }, owner: { ["test-owner"] }, live: { true }, pause: {})
    }
    func testStrictBoundariesAndIndependentlyExpiringProposal() throws {
        let report = page(), preview = try XCTUnwrap(report.proposal)
        try report.validate(for: .left)
        XCTAssertTrue(report.matches(preview, at: now))
        XCTAssertFalse(report.current(at: now.addingTimeInterval(-1)))
        XCTAssertFalse(report.current(at: now.addingTimeInterval(20)))
        XCTAssertThrowsError(try report.validate(for: .right))
        XCTAssertFalse(page(offset: 1).current(at: now))
        for target in [54, 67, 70, 111] {
            XCTAssertThrowsError(try TemporaryCooling.Proposal(scope: preview.scope, fromTargetF: 70, targetF: target, expiresAt: preview.expiresAt).validate())
        }
        let later = TemporaryCooling.Proposal(scope: preview.scope, fromTargetF: 70, targetF: 68, expiresAt: preview.expiresAt + 1)
        XCTAssertFalse(report.matches(later, at: now))
        let expired = TemporaryCooling.Proposal(scope: preview.scope, fromTargetF: 70, targetF: 68, expiresAt: report.generatedAt + 59_999)
        XCTAssertFalse(report.matches(expired, at: now))
    }
    func testMalformedStateTimesAndPhysicalClaimsAreRejected() throws {
        let data = try JSONEncoder().encode(page())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("apiVersion", 2 as Any), ("state", "unknown" as Any), ("physicalVerification", "verified" as Any),
                             ("observedAt", Int64(now.timeIntervalSince1970 * 1000) + 1 as Any)] {
            var fields = original; fields[key] = value
            let report = try JSONDecoder().decode(TemporaryCooling.self, from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertThrowsError(try report.validate(for: .left)); XCTAssertFalse(report.current(at: now))
        }
    }
    func testStartAndCancelUseOneRetainedCommandEachAndPreserveTheReviewedDeadline() async throws {
        let report = page(), read = CoolingReadFixture(report: report), commands = CoolingCommandFixture()
        let ledger = NativeControlLedger(directory: nil), model = TemporaryCoolingWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        model.configure(side: .left, client: read, controls: controls(commands, ledger: ledger)); await model.refresh()
        await model.start(try XCTUnwrap(report.proposal))
        var posts = await commands.posts
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(posts[0].action.expectedExpiresAt, report.proposal?.expiresAt)
        XCTAssertEqual(posts[0].action.expectedTargetF, 70); XCTAssertEqual(posts[0].action.side, .left)
        XCTAssertEqual(try ledger.read(scope: ["test-owner"]).first?.request, posts[0])
        let lease = TemporaryCooling.Lease(version: 1, id: try XCTUnwrap(posts[0].action.coolingId), side: .left,
            scope: try XCTUnwrap(report.proposal?.scope), fromTargetF: 70, targetF: 68, startedAt: report.generatedAt,
            expiresAt: report.generatedAt + 1_200_000, sessionEndsAt: report.generatedAt + 3_600_000, phase: "active")
        await read.set(.init(apiVersion: 1, side: .left, generatedAt: report.generatedAt, state: "cooling", reason: "Synthetic active",
                            observedAt: report.observedAt, proposal: nil, lease: lease, physicalVerification: "unverified"))
        await model.refresh(); await model.cancel()
        posts = await commands.posts
        XCTAssertEqual(posts.count, 2); XCTAssertEqual(posts[1].action.kind, "cooling.cancel")
        XCTAssertEqual(posts[1].action.coolingId, posts[0].action.coolingId)
    }
    func testCancellationHasDistinctProgressUntilItsHeldRequestCompletes() async throws {
        let initial = page(), commands = CoolingCommandFixture(holdAvailability: true)
        let lease = TemporaryCooling.Lease(version: 1, id: UUID().uuidString.lowercased(), side: .left,
            scope: String(repeating: "a", count: 64), fromTargetF: 70, targetF: 68, startedAt: initial.generatedAt,
            expiresAt: initial.generatedAt + 1_200_000, sessionEndsAt: initial.generatedAt + 3_600_000, phase: "active")
        let active = TemporaryCooling(apiVersion: 1, side: .left, generatedAt: initial.generatedAt, state: "cooling", reason: "Synthetic",
            observedAt: initial.observedAt, proposal: nil, lease: lease, physicalVerification: "unverified")
        let model = TemporaryCoolingWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        model.configure(side: .left, client: CoolingReadFixture(report: active), controls: controls(commands)); await model.refresh()
        let operation = Task { await model.cancel() }; await commands.waitUntilHeld()
        XCTAssertEqual(model.operation, .cancelling); XCTAssertTrue(model.busy)
        await model.cancel()
        await commands.release(); await operation.value
        XCTAssertNil(model.operation); XCTAssertFalse(model.busy)
        let posts = await commands.posts; XCTAssertEqual(posts.count, 1)
    }
    func testLostReplyRemainsReviewableAcrossReopenAndNeverResubmits() async throws {
        let report = page(), read = CoolingReadFixture(report: report), commands = CoolingCommandFixture(offline: true)
        let ledger = NativeControlLedger(directory: nil), model = TemporaryCoolingWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        model.configure(side: .left, client: read, controls: controls(commands, ledger: ledger)); await model.refresh()
        let preview = try XCTUnwrap(report.proposal)
        await model.start(preview)
        XCTAssertTrue(model.attempt?.needsReview == true)
        await model.checkRequest(); await model.start(preview)
        let reopened = TemporaryCoolingWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        reopened.configure(side: .left, client: read, controls: controls(commands, ledger: ledger)); await reopened.refresh()
        await reopened.start(preview)
        let posts = await commands.posts, reads = await commands.reads
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(reads.count, 2); XCTAssertTrue(reads.allSatisfy { $0 == posts[0] })
        XCTAssertEqual(try ledger.read(scope: ["test-owner"]).count, 1)
    }
    func testExpiredOrChangedPreviewMakesNoRequest() async throws {
        let report = page(), read = CoolingReadFixture(report: report), commands = CoolingCommandFixture()
        var clock = now
        let model = TemporaryCoolingWorkspace(currentOwner: { ["owner"] }, now: { clock })
        model.configure(side: .left, client: read, controls: controls(commands)); await model.refresh()
        clock = now.addingTimeInterval(21); await model.start(try XCTUnwrap(report.proposal))
        clock = now
        await model.start(.init(scope: String(repeating: "b", count: 64), fromTargetF: 70, targetF: 68, expiresAt: report.proposal!.expiresAt))
        let posts = await commands.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testCancelCanResolveAnUncertainStartButCannotReplayAnUncertainCancellation() async throws {
        let commands = CoolingCommandFixture(offline: true), ledger = NativeControlLedger(directory: nil)
        let controller = controls(commands, ledger: ledger), identifier = UUID().uuidString.lowercased()
        let start = NativeControlAction(kind: "cooling.start", side: .left, coolingId: identifier,
            expectedScope: String(repeating: "a", count: 64), expectedTargetF: 70, expectedExpiresAt: 1_794_351_200_000)
        _ = try await controller.submit(start)
        let cancel = NativeControlAction(kind: "cooling.cancel", side: .left, coolingId: identifier)
        _ = try await controller.submit(cancel)
        do { _ = try await controls(commands, ledger: ledger).submit(cancel); XCTFail("An uncertain return must not be sent twice") } catch {}
        _ = try await controller.submit(.init(kind: "power", side: .left, powered: false))
        let posts = await commands.posts
        XCTAssertEqual(posts.map(\.action.kind), ["cooling.start", "cooling.cancel", "power"])
    }
    func testSideOrOwnerChangeDuringCapabilityCheckPreventsDispatch() async throws {
        for changeSide in [true, false] {
            let report = page(), read = CoolingReadFixture(report: report), commands = CoolingCommandFixture(holdAvailability: true)
            var owner: [String]? = ["owner"]
            let model = TemporaryCoolingWorkspace(currentOwner: { owner }, now: { self.now })
            model.configure(side: .left, client: read, controls: controls(commands)); await model.refresh()
            let operation = Task { await model.start(report.proposal!) }
            await commands.waitUntilHeld()
            XCTAssertEqual(model.operation, .starting(report.proposal!)); XCTAssertTrue(model.busy)
            if changeSide { model.configure(side: .right, client: read, controls: controls(commands)) } else { owner = ["other-owner"] }
            await commands.release(); await operation.value
            let posts = await commands.posts; XCTAssertTrue(posts.isEmpty); XCTAssertNil(model.report); XCTAssertNil(model.operation)
        }
    }
    func testPreviewExpiringDuringCapabilityCheckPreventsDispatch() async throws {
        let report = page(), commands = CoolingCommandFixture(holdAvailability: true)
        var clock = now
        let model = TemporaryCoolingWorkspace(currentOwner: { ["owner"] }, now: { clock })
        model.configure(side: .left, client: CoolingReadFixture(report: report), controls: controls(commands)); await model.refresh()
        let operation = Task { await model.start(report.proposal!) }
        await commands.waitUntilHeld(); clock = now.addingTimeInterval(21)
        await commands.release(); await operation.value
        let posts = await commands.posts; XCTAssertTrue(posts.isEmpty)
    }
    func testFailedRefreshAndOwnerChangeWithdrawThePreviousData() async {
        var owner: [String]? = ["owner"]
        let client = CoolingReadFixture(report: page()), model = TemporaryCoolingWorkspace(currentOwner: { owner })
        model.configure(side: .left, client: client, controls: nil); await model.refresh(); XCTAssertNotNil(model.report)
        await client.fail(); await model.refresh(); XCTAssertNil(model.report)
        model.configure(side: .left, client: CoolingReadFixture(report: page()), controls: nil); await model.refresh()
        owner = nil; XCTAssertNil(model.report)
    }
    func testLateReadCannotPublishAcrossSideChange() async {
        let client = CoolingReadFixture(report: page(), hold: true), model = TemporaryCoolingWorkspace(currentOwner: { ["owner"] })
        model.configure(side: .left, client: client, controls: nil)
        let operation = Task { await model.refresh() }; await client.waitUntilHeld()
        model.configure(side: .right, client: client, controls: nil)
        await client.release(); await operation.value
        XCTAssertNil(model.report); XCTAssertFalse(model.busy)
    }
    func testOnlyCoolingFieldsCanCrossTheCommandContract() throws {
        var start = NativeControlAction(kind: "cooling.start", side: .left, coolingId: UUID().uuidString.lowercased(),
            expectedScope: String(repeating: "a", count: 64), expectedTargetF: 70, expectedExpiresAt: 1_794_351_200_000)
        try start.validate(); XCTAssertEqual(start.family, "left-thermal"); XCTAssertFalse(start.isStopping)
        start.temperature = 67; XCTAssertThrowsError(try start.validate())
        let cancel = NativeControlAction(kind: "cooling.cancel", side: .left, coolingId: UUID().uuidString.lowercased())
        try cancel.validate(); XCTAssertTrue(cancel.isStopping)
        var invalid = cancel; invalid.expectedScope = String(repeating: "a", count: 64); XCTAssertThrowsError(try invalid.validate())
    }
    func testCoolingReadUsesFixedGETRouteAndPhysicalSideOnly() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoolingReadProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let transport = CoreRESTClient(endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:3000")), session: session)
        let result = try await CoreTemporaryCoolingClient(transport: transport).read(side: .right)
        XCTAssertEqual(result.side, .right)
    }
}

private actor CoolingReadFixture: TemporaryCoolingClient {
    var report: TemporaryCooling
    private var failed = false
    private var holding: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(report: TemporaryCooling, hold: Bool = false) { self.report = report; holding = hold }
    func fail() { failed = true }
    func set(_ report: TemporaryCooling) { self.report = report }
    func read(side: Side) async throws -> TemporaryCooling {
        if holding { holding = false; await withCheckedContinuation { continuation = $0 } }
        if failed { throw URLError(.notConnectedToInternet) }
        return report
    }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor CoolingCommandFixture: NativeControlClient {
    private let offline: Bool
    private var holding: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var posts: [NativeControlRequest] = []
    private(set) var reads: [NativeControlRequest] = []
    init(offline: Bool = false, holdAvailability: Bool = false) { self.offline = offline; holding = holdAvailability }
    func available() async { if holding { holding = false; await withCheckedContinuation { continuation = $0 } } }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func submit(_ request: NativeControlRequest) throws -> NativeControlReceipt {
        posts.append(request)
        if offline { throw URLError(.networkConnectionLost) }
        return receipt(request)
    }
    func read(_ request: NativeControlRequest) throws -> NativeControlReceipt {
        reads.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        return receipt(request)
    }
    private func receipt(_ request: NativeControlRequest) -> NativeControlReceipt {
        .init(version: 1, requestId: request.requestId, action: request.action, issuedAt: request.issuedAt,
              expiresAt: request.expiresAt, receivedAt: request.issuedAt, finishedAt: request.issuedAt, lastDispatchAt: request.issuedAt,
              state: "acknowledged", reason: nil, dispatchCount: 1, physicalVerification: "unverified", replayAllowed: false)
    }
}
private final class CoolingReadProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/api/device/cooling"); XCTAssertEqual(request.url?.query, "side=right")
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        let json = #"{"apiVersion":1,"side":"right","generatedAt":1794350000000,"state":"unavailable","reason":"No powered zone","observedAt":null,"proposal":null,"lease":null,"physicalVerification":"unverified"}"#
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
