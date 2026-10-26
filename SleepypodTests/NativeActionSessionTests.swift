import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class NativeActionSessionTests: XCTestCase {
    private func session(_ client: ActionSessionTestClient, owner: ActionSessionTestOwner = .init()) -> NativeActionSession {
        .init(controls: .failure(NativeControlFailure.unavailable), personal: { client }, alarms: { client }, comfort: { client }, owner: { owner.scope }, live: { owner.live })
    }
    func testIntentCommandsUseCorePresetsWholeDegreesAndWholeBedScope() throws {
        let presets = ["flat": (0, 0), "sleep": (1, 5), "relax": (30, 15), "read": (40, 0)]
        for (name, position) in presets {
            XCTAssertEqual(try NativeActionSession.command(.preset(name)), .init(kind: "base.position", head: position.0, feet: position.1, feedRate: 50))
        }
        XCTAssertEqual(try NativeActionSession.command(.temperature(side: "right", value: 68)), .init(kind: "temperature", side: .right, temperature: 68))
        XCTAssertEqual(try NativeActionSession.command(.dismissAlarm(side: "left")), .init(kind: "vibration.clear", side: .left))
        XCTAssertEqual(try NativeActionSession.command(.stopBase), .init(kind: "base.stop"))
        for action: NativePodAction in [.temperature(side: "right", value: 68.5), .temperature(side: "left", value: .nan), .temperature(side: "both", value: 68),
            .position(head: 61, feet: 0), .position(head: 0, feet: 46), .preset("unknown")] { XCTAssertThrowsError(try NativeActionSession.command(action)) }
    }
    func testReadAwayAndPrimeUseOnlyTheRequestedOperations() async throws {
        let client = ActionSessionTestClient(), session = session(client)
        let reading = try await session.perform(.readTemperature(side: "right", current: false))
        XCTAssertEqual(reading, .number(82))
        _ = try await session.perform(.away(side: "left", enabled: true)); _ = try await session.perform(.prime)
        let calls = await client.calls(); XCTAssertEqual(calls, ["temperature:right:false", "away:left:true", "prime"])
    }
    func testAlarmChangesPreserveOccurrenceRevisionsAndNeverRetryLostWrites() async throws {
        let client = ActionSessionTestClient(), session = session(client)
        _ = try await session.perform(.changeAlarm(side: "left", action: "time", time: "08:00"))
        var writes = await client.writes()
        let base = try XCTUnwrap(NextAlarmExample.load().cases["scheduled"])
        XCTAssertEqual(writes, [try .init(base: base, action: "time", time: "08:00")])
        await client.setLost(true)
        do { _ = try await session.perform(.changeAlarm(side: "left", action: "skip", time: nil)); XCTFail("Lost write must surface") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not repeated")) }
        writes = await client.writes(); XCTAssertEqual(writes.count, 2)
        let calls = await client.calls(); XCTAssertEqual(calls.filter { $0 == "alarm.read" }.count, 2)
    }
    func testModeOnlyChangePreservesNewerLimitsAndBlocksActive() async throws {
        let client = ActionSessionTestClient(), session = session(client)
        _ = try await session.perform(.comfort(side: "right", mode: "preview"))
        let config = try await client.savedConfig()
        XCTAssertEqual(config.minimumF, 65); XCTAssertEqual(config.maximumF, 88); XCTAssertEqual(config.mode, "preview")
        do { _ = try await session.perform(.comfort(side: "right", mode: "active")); XCTFail("Active is unqualified") } catch {}
        let calls = await client.calls(); XCTAssertEqual(calls, ["comfort.read", "comfort.mode:preview"])
    }
    func testOwnerChangeDuringAlarmReadPreventsWriteAndLatePublication() async throws {
        let client = ActionSessionTestClient(), owner = ActionSessionTestOwner(), session = session(client, owner: owner)
        await client.hold()
        let task = Task { try await session.perform(.changeAlarm(side: "left", action: "skip", time: nil)) }
        await client.waitHeld(); owner.scope = ["new"]; await client.release()
        do { _ = try await task.value; XCTFail("Old owner must not write") } catch {}
        let writes = await client.writes(); XCTAssertTrue(writes.isEmpty)
    }
    func testDemoAndCancellationPerformNoClientOperation() async throws {
        let client = ActionSessionTestClient(), owner = ActionSessionTestOwner(), session = session(client, owner: owner)
        owner.live = false
        do { _ = try await session.perform(.prime); XCTFail("Demo cannot prime") } catch {}
        owner.live = true
        let task = Task { try await session.perform(.prime) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled action cannot prime") } catch {}
        let calls = await client.calls(); XCTAssertTrue(calls.isEmpty)
    }
}
@MainActor private final class ActionSessionTestOwner { var scope = ["owner"]; var live = true }
private actor ActionSessionTestClient: NativePersonalActionClient, NextAlarmClient, PersonalComfortClient {
    private var captured: [String] = []
    private var inputs: [NextAlarmWrite] = []
    private var lost = false
    private var holding = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let comfort = DemoPersonalComfortClient()
    func calls() -> [String] { captured }
    func writes() -> [NextAlarmWrite] { inputs }
    func setLost(_ value: Bool) { lost = value }
    func hold() { holding = true }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func temperature(side: Side, current: Bool) async throws -> Double { captured.append("temperature:\(side.rawValue):\(current)"); return 82 }
    func away(side: Side, enabled: Bool) async throws { captured.append("away:\(side.rawValue):\(enabled)") }
    func prime() async throws { captured.append("prime") }
    func available() async throws {}
    func read(side: Side) async throws -> NextAlarmState {
        captured.append("alarm.read")
        if holding { holding = false; await withCheckedContinuation { continuation = $0 } }
        return try NextAlarmExample.load().cases["scheduled"]!
    }
    func write(_ input: NextAlarmWrite) async throws -> NextAlarmState {
        inputs.append(input)
        if lost { throw URLError(.networkConnectionLost) }
        let example = try NextAlarmExample.load().cases["changed"]!
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(example)) as! [String: Any]
        object["schedulerUpdated"] = false
        return try JSONDecoder().decode(NextAlarmState.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func status(side: Side) async throws -> PersonalComfortStatus {
        captured.append("comfort.read")
        let original = try await comfort.status(side: side)
        // Another client changes limits after this read but before the mode-only mutation.
        _ = try await comfort.configure(side: side, config: .init(mode: "off", minimumF: 65, maximumF: 88))
        return original
    }
    func savedConfig() async throws -> PersonalComfortConfig { try await comfort.status(side: .right).state!.config }
    func mode(side: Side, mode: String) async throws -> PersonalComfortStatus { captured.append("comfort.mode:\(mode)"); return try await comfort.mode(side: side, mode: mode) }
    func configure(side: Side, config: PersonalComfortConfig) async throws -> PersonalComfortStatus { throw NativeControlFailure.invalid }
    func feedback(side: Side, input: PersonalComfortFeedback) async throws -> PersonalComfortStatus { throw NativeControlFailure.invalid }
    func reports(side: Side) async throws -> ComfortNightList { throw NativeControlFailure.invalid }
    func report(side: Side, id: String, after: Int?) async throws -> ComfortNightDetail { throw NativeControlFailure.invalid }
    func review(_ input: ComfortReviewInput) async throws -> ComfortNightReview { throw NativeControlFailure.invalid }
}
