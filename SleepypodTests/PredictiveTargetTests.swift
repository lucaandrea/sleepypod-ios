import XCTest
@testable import Sleepypod

@MainActor final class PredictiveTargetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSharedCorePolicyFixtureAndStrictExpiry() throws {
        let value = try PredictiveTargetExample.value(now: now)
        try value.validate(side: .left, now: now)
        XCTAssertEqual(value.disposition, .candidate); XCTAssertEqual(value.proposedTargetF, 69)
        XCTAssertEqual(value.comparisons.map(\.targetF), [70, 69, 71]); XCTAssertFalse(value.activationAvailable)
        XCTAssertThrowsError(try value.validate(side: .right, now: now))
        XCTAssertThrowsError(try value.validate(side: .left, now: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try value.validate(side: .left, now: now.addingTimeInterval(15)))
    }
    func testContradictoryIdentitySelectionAndRangesAreRejected() throws {
        for defect in ["policy", "activation", "selection", "kind", "expiry", "bounds", "horizon", "range", "score", "duplicate", "withheld"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PredictiveTargetExample.value(now: now))) as? [String: Any])
            var comparisons = try XCTUnwrap(object["comparisons"] as? [[String: Any]])
            switch defect {
            case "policy": object["policy"] = "another-policy"
            case "activation": object["activationAvailable"] = true
            case "selection": object["proposedTargetF"] = 68
            case "kind": object["disposition"] = "hold"
            case "withheld": object["disposition"] = "withheld"
            case "expiry": object["expiresAt"] = now.timeIntervalSince1970 * 1000 + 60_000
            case "bounds": object["minimumF"] = 70
            case "horizon": comparisons[0]["predictions"] = []
            case "score": comparisons[0]["bestErrorF"] = -1
            case "duplicate": comparisons[2] = comparisons[1]
            case "range":
                var predictions = try XCTUnwrap(comparisons[0]["predictions"] as? [[String: Any]])
                predictions[0]["lowerF"] = 100; comparisons[0]["predictions"] = predictions
            default: break
            }
            object["comparisons"] = comparisons
            let result = try JSONDecoder().decode(PredictiveTargetPreview.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try result.validate(side: .left, now: now), defect)
        }
    }
    func testExplicitReadExpiresWithoutAnotherRequestAndWithdrawsOnAccountChange() async throws {
        let client = PredictiveReadClient(value: try PredictiveTargetExample.value(now: now))
        var owner: [String]? = ["owner"]
        let workspace = PredictiveTargetWorkspace(currentOwner: { owner }, now: { self.now })
        workspace.configure(client: client, side: .left)
        XCTAssertNil(workspace.preview(at: now))
        await workspace.refresh()
        XCTAssertNotNil(workspace.preview(at: now)); XCTAssertNil(workspace.preview(at: now.addingTimeInterval(15)))
        owner = nil
        XCTAssertNil(workspace.preview(at: now))
        await workspace.refresh()
        let count = await client.count; XCTAssertEqual(count, 1)
    }
    func testFailedReadRemovesPreviousSelectionAndPersonalAccountCannotRead() async throws {
        let client = PredictiveReadClient(value: try PredictiveTargetExample.value(now: now))
        let workspace = PredictiveTargetWorkspace(currentOwner: { ["owner"] }, now: { self.now })
        workspace.configure(client: client, side: .left); await workspace.refresh()
        await client.fail(); await workspace.refresh()
        XCTAssertNil(workspace.preview(at: now)); XCTAssertNotNil(workspace.error)
        let personal = PredictiveTargetWorkspace(currentOwner: { nil }, now: { self.now })
        personal.configure(client: client, side: .left); await personal.refresh()
        let count = await client.count; XCTAssertEqual(count, 2)
    }
    func testLateResponseCannotCrossConnectionSideBackgroundOrCancellation() async throws {
        for change in ["side", "owner", "background", "cancel"] {
            var owner: [String]? = ["owner"]
            let client = DeferredPredictiveClient()
            let workspace = PredictiveTargetWorkspace(currentOwner: { owner }, now: { self.now })
            workspace.configure(client: client, side: .left)
            let task = Task { await workspace.refresh() }
            await client.waitUntilStarted()
            if change == "side" { workspace.configure(client: client, side: .right) }
            if change == "owner" { owner = ["another"] }
            if change == "background" { workspace.invalidate() }
            if change == "cancel" { task.cancel() }
            await client.finish(try PredictiveTargetExample.value(now: now)); await task.value
            XCTAssertNil(workspace.preview(at: now)); XCTAssertFalse(workspace.busy)
        }
    }
}

private actor PredictiveReadClient: PredictiveTargetClient {
    let value: PredictiveTargetPreview
    private var failed = false
    private(set) var count = 0
    init(value: PredictiveTargetPreview) { self.value = value }
    func fail() { failed = true }
    func preview(side: Side) throws -> PredictiveTargetPreview {
        count += 1
        if failed { throw URLError(.notConnectedToInternet) }
        return value
    }
}
private actor DeferredPredictiveClient: PredictiveTargetClient {
    private var reply: CheckedContinuation<PredictiveTargetPreview, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func preview(side: Side) async -> PredictiveTargetPreview {
        await withCheckedContinuation { reply = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if reply != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ value: PredictiveTargetPreview) { reply?.resume(returning: value); reply = nil }
}
