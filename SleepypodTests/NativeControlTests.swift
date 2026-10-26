import XCTest
@testable import Sleepypod

@MainActor final class NativeControlTests: XCTestCase {
    private let temperature = NativeControlAction(kind: "temperature", side: .left, temperature: 68, holdMinutes: 30)
    private func service(_ client: CommandTestClient, ledger: NativeControlLedger = .init(directory: nil), owner: CommandTestOwner = .init()) -> NativeControlService {
        .init(ledger: ledger, client: { client }, owner: { owner.value }, live: { owner.live }, pause: {})
    }
    func testActualCoreStatesAndStrictActionsDecodeWithoutPhysicalSuccessClaims() throws {
        struct Example: Decodable {
            struct Pair: Decodable { let request: NativeControlRequest; let receipt: NativeControlReceipt }
            let synthetic: Bool; let cases: [String: Pair]; let actions: [NativeControlAction]
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "control-receipts-example", withExtension: "json"))
        let example = try JSONDecoder().decode(Example.self, from: Data(contentsOf: url))
        XCTAssertTrue(example.synthetic); XCTAssertEqual(example.cases.count, 6)
        for (name, pair) in example.cases {
            try pair.receipt.validate(for: pair.request); XCTAssertEqual(pair.receipt.state, name)
            XCTAssertEqual(pair.receipt.physicalVerification, "unverified"); XCTAssertFalse(pair.receipt.replayAllowed)
        }
        for action in example.actions { try action.validate() }
        var invalid = temperature; invalid.head = 30; XCTAssertThrowsError(try invalid.validate())
        invalid = temperature; invalid.temperature = 111; XCTAssertThrowsError(try invalid.validate())
        invalid = temperature; invalid.holdMinutes = 0; XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try NativeControlAction(kind: "base.position", head: 0, feet: 0, feedRate: 25).validate())
        let request = try NativeControlRequest(action: temperature)
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(fields["requestId"] as? String, request.requestId.uuidString.lowercased())
        XCTAssertEqual(request.expiresAt - request.issuedAt, 30_000)
    }
    func testRequestIsDurableBeforeDispatchAndLostReplyUsesOnlySameIDReadback() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = NativeControlLedger(directory: directory), client = CommandTestClient(mode: "lost")
        await client.inspect { request in
            XCTAssertEqual(try NativeControlLedger(directory: directory).read(scope: ["owner"]).first?.request, request)
        }
        let value = try await service(client, ledger: ledger).submit(temperature)
        XCTAssertEqual(value.receipt?.state, "acknowledged"); XCTAssertFalse(value.needsReview)
        let calls = await client.calls(); XCTAssertEqual(calls.posts.count, 1); XCTAssertEqual(calls.reads, [calls.posts[0]])
        XCTAssertEqual(try NativeControlLedger(directory: directory).read(scope: ["owner"]), [value])
    }
    func testUnknownBlocksRelatedCommandButStopAndReviewNeverReplayIt() async throws {
        let client = CommandTestClient(mode: "unknown"), controller = service(client)
        let original = try await controller.submit(.init(kind: "base.position", head: 30, feet: 15, feedRate: 50))
        do { _ = try await controller.submit(.init(kind: "base.position", head: 0, feet: 0, feedRate: 50)); XCTFail("Unreviewed outcome must block another movement") } catch {}
        _ = try await controller.submit(.init(kind: "base.stop"))
        var calls = await client.calls(); XCTAssertEqual(calls.posts.count, 2)
        try controller.review(original.id)
        let reviewed = try XCTUnwrap(controller.history().first(where: { $0.id == original.id }))
        XCTAssertEqual(reviewed.receipt?.state, "unknown"); XCTAssertNotNil(reviewed.reviewedAt)
        // The stopping command is unknown too; reviewing it permits a deliberate new movement.
        for value in try controller.history() where value.needsReview { try controller.review(value.id) }
        _ = try await controller.submit(.init(kind: "base.position", head: 0, feet: 0, feedRate: 50))
        calls = await client.calls(); XCTAssertEqual(calls.posts.count, 3)
        XCTAssertEqual(Set(calls.posts.map(\.requestId)).count, 3)
    }
    func testMissingReceiptPersistsAcrossReopenAndPowerOffRemainsAvailable() async throws {
        let client = CommandTestClient(mode: "offline"), ledger = NativeControlLedger(directory: nil)
        let original = try await service(client, ledger: ledger).submit(temperature)
        XCTAssertNil(original.receipt); XCTAssertTrue(original.needsReview)
        let reopened = service(client, ledger: ledger)
        do { _ = try await reopened.submit(temperature); XCTFail("Reopen must not erase pending state") } catch {}
        _ = try await reopened.submit(.init(kind: "power", side: .left, powered: false))
        let calls = await client.calls(); XCTAssertEqual(calls.posts.count, 2); XCTAssertEqual(calls.posts.first, original.request)
    }
    func testPersistenceFailureAndDemoPreventDispatch() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("file".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let client = CommandTestClient(), ledger = NativeControlLedger(directory: file)
        do { _ = try await service(client, ledger: ledger).submit(temperature); XCTFail("A retained request is required") } catch {}
        let owner = CommandTestOwner(); owner.live = false
        do { _ = try await service(client, owner: owner).submit(temperature); XCTFail("Demo cannot send") } catch {}
        let calls = await client.calls(); XCTAssertTrue(calls.posts.isEmpty)
    }
    func testCancellationAndOwnerChangeRetainLateReceiptWithoutNewOwnerPublication() async throws {
        let client = CommandTestClient(), ledger = NativeControlLedger(directory: nil), owner = CommandTestOwner()
        let controller = service(client, ledger: ledger, owner: owner)
        await client.hold()
        let operation = Task { try await controller.submit(temperature) }; await client.waitUntilHeld()
        operation.cancel(); owner.value = ["other-owner"]; await client.release()
        do { _ = try await operation.value; XCTFail("Cancelled invocation cannot report success") } catch {}
        XCTAssertTrue(try controller.history().isEmpty)
        XCTAssertEqual(try ledger.read(scope: ["owner"]).first?.receipt?.state, "acknowledged")
        let calls = await client.calls(); XCTAssertEqual(calls.posts.count, 1)
    }
    func testExecutingPollsAreBoundedAndManualRefreshOnlyReads() async throws {
        let client = CommandTestClient(mode: "executing"), controller = service(client)
        let value = try await controller.submit(temperature)
        XCTAssertTrue(value.needsReview); XCTAssertEqual(value.receipt?.state, "executing")
        var calls = await client.calls(); XCTAssertEqual(calls.posts.count, 1); XCTAssertEqual(calls.reads.count, 3)
        await client.mode("acknowledged")
        let final = try await controller.refresh(value.id); XCTAssertEqual(final.receipt?.state, "acknowledged")
        calls = await client.calls(); XCTAssertEqual(calls.posts.count, 1); XCTAssertEqual(calls.reads.count, 4)
        XCTAssertTrue(calls.reads.allSatisfy { $0 == value.request })
    }
    func testMalformedReceiptCannotReplaceRetainedRequest() async throws {
        let client = CommandTestClient(mode: "wrong-id"), controller = service(client)
        do { _ = try await controller.submit(temperature); XCTFail("Wrong receipt identity must fail") } catch {}
        let attempt = try XCTUnwrap(controller.history().first)
        XCTAssertNil(attempt.receipt); XCTAssertTrue(attempt.needsReview)
        let calls = await client.calls(); XCTAssertEqual(calls.posts.count, 1)
    }
}

@MainActor private final class CommandTestOwner { var value = ["owner"]; var live = true }
private actor CommandTestClient: NativeControlClient {
    private var scenario: String
    private var posts: [NativeControlRequest] = []
    private var reads: [NativeControlRequest] = []
    private var inspectRequest: (@MainActor @Sendable (NativeControlRequest) throws -> Void)?
    private var holding = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(mode: String = "acknowledged") { scenario = mode }
    func available() async throws {}
    func inspect(_ callback: @escaping @MainActor @Sendable (NativeControlRequest) throws -> Void) { inspectRequest = callback }
    func mode(_ value: String) { scenario = value }
    func calls() -> (posts: [NativeControlRequest], reads: [NativeControlRequest]) { (posts, reads) }
    func hold() { holding = true }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func submit(_ request: NativeControlRequest) async throws -> NativeControlReceipt {
        try await inspectRequest?(request); posts.append(request)
        if holding { holding = false; await withCheckedContinuation { continuation = $0 } }
        if ["lost", "offline"].contains(scenario) { throw URLError(.networkConnectionLost) }
        return receipt(request)
    }
    func read(_ request: NativeControlRequest) async throws -> NativeControlReceipt {
        reads.append(request)
        if scenario == "offline" { throw URLError(.notConnectedToInternet) }
        return receipt(request)
    }
    private func receipt(_ request: NativeControlRequest) -> NativeControlReceipt {
        let state = ["executing", "unknown"].contains(scenario) ? scenario : "acknowledged"
        return .init(version: 1, requestId: scenario == "wrong-id" ? UUID() : request.requestId, action: request.action,
            issuedAt: request.issuedAt, expiresAt: request.expiresAt, receivedAt: request.issuedAt,
            finishedAt: state == "executing" ? nil : request.issuedAt + 1, lastDispatchAt: request.issuedAt,
            state: state, reason: nil, dispatchCount: 1, physicalVerification: "unverified", replayAllowed: false)
    }
}
