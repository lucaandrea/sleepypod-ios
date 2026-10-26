import XCTest
@testable import Sleepypod

@MainActor final class ControllerScopeTests: XCTestCase {
    func testAlarmOwnerChangeDuringPreflightCancelsUnsentEdit() async throws {
        let first = PausingAlarmClient(), second = PausingAlarmClient()
        let model = AlarmWorkspace(api: first, demo: true)
        await model.refresh(); await first.holdNextRead()
        var draft = AlarmDraft(sides: [.left]); draft.days = [.monday]
        let edit = Task { await model.save(draft) }
        await waitForRead { await first.waiting }
        model.configure(api: second, demo: true); await model.refresh()
        await first.releaseRead()
        let saved = await edit.value
        XCTAssertFalse(saved); XCTAssertTrue(model.loaded); XCTAssertFalse(model.saving)
        let oldWrites = await first.writes, newWrites = await second.writes
        XCTAssertEqual(oldWrites, 0); XCTAssertEqual(newWrites, 0); XCTAssertNil(model.error)
    }

    func testCurveOwnerChangeDuringPreflightCancelsUnsentEdit() async throws {
        let first = PausingCurveClient(), second = PausingCurveClient()
        let model = CurveWorkspace(api: first)
        await model.refresh(); await first.holdNextRead()
        var draft = CurveDraft(); draft.name = "Previous controller"; draft.generate(.balanced)
        let edit = Task { await model.save(draft, reviewed: []) }
        await waitForRead { await first.waiting }
        model.configure(api: second); await model.refresh()
        await first.releaseRead()
        let saved = await edit.value
        XCTAssertFalse(saved); XCTAssertTrue(model.loaded); XCTAssertFalse(model.saving)
        let oldWrites = await first.writes, newWrites = await second.writes
        XCTAssertEqual(oldWrites, 0); XCTAssertEqual(newWrites, 0); XCTAssertNil(model.error)
    }

    func testUnavailableClientsDoNotAdoptALaterSavedEndpoint() async {
        let alarms = CoreAlarmClient(client: nil), curves = CoreCurveClient(transport: nil)
        let original = UserDefaults.standard.object(forKey: "podURL")
        defer { UserDefaults.standard.set(original, forKey: "podURL") }
        UserDefaults.standard.set("https://changed-owner.invalid", forKey: "podURL")
        do { _ = try await alarms.all(); XCTFail("A missing frozen connection must stay unavailable") }
        catch APIError.noBaseURL {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await curves.library(); XCTFail("A missing frozen connection must stay unavailable") }
        catch APIError.noBaseURL {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func waitForRead(_ waiting: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { if await waiting() { return }; await Task.yield() }
        XCTFail("The preflight read did not begin")
    }
}

private actor PausingAlarmClient: AlarmClient {
    var writes = 0
    var waiting = false
    private var hold = false
    private var read: CheckedContinuation<Void, Never>?
    func holdNextRead() { hold = true }
    func releaseRead() { read?.resume(); read = nil }
    func all() async -> [CoreAlarmRow] {
        if hold { hold = false; waiting = true; await withCheckedContinuation { read = $0 }; waiting = false }
        return []
    }
    func apply(_ batch: AlarmBatch) { writes += 1 }
    func test(_ job: AlarmJob) { writes += 1 }
    func stop(_ side: Side) { writes += 1 }
}

private actor PausingCurveClient: CurveClient {
    var writes = 0
    var waiting = false
    private var hold = false
    private var read: CheckedContinuation<Void, Never>?
    func holdNextRead() { hold = true }
    func releaseRead() { read?.resume(); read = nil }
    func library() async -> CurveLibrarySnapshot {
        if hold { hold = false; waiting = true; await withCheckedContinuation { read = $0 }; waiting = false }
        return .init(curves: [], supportsAssignments: true)
    }
    func put(_ input: CurvePut, assignments: Bool) throws -> CurveChange { writes += 1; throw APIError.noBaseURL }
    func delete(_ curve: PodCurve) { writes += 1 }
    func active(_ side: Side) -> RunOnceSession? { nil }
    func start(side: Side, points: [RunOnceSetPoint], wake: String) throws -> RunOnceStartResponse { writes += 1; throw APIError.noBaseURL }
    func cancel(_ side: Side) { writes += 1 }
}
