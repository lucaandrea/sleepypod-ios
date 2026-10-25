import Foundation
import XCTest
@testable import Sleepypod

@MainActor
final class CurveParityTests: XCTestCase {
    private func curve(_ id: Int = 1, name: String = "Weeknight") -> PodCurve {
        PodCurve(id: id, name: name, bedtime: "22:00", wake: "07:00", points: ["22:00": 76, "02:00": 68, "07:00": 80], notes: "Keep fractional readings", endAction: .maintain, days: CurveDays(left: [.monday, .tuesday], right: [.friday]), active: true)
    }
    func testOvernightOrderingAndRebaseDoNotDependOnPhoneTimezone() {
        let points = curve().ordered
        XCTAssertEqual(points.map(\.time), ["22:00", "02:00", "07:00"])
        let moved = CurvePoint.rebase(points, from: "22:00", until: "07:00", to: "23:00", until: "08:00")
        XCTAssertEqual(moved.map(\.time), ["23:00", "03:00", "08:00"])
        XCTAssertEqual(moved.map(\.temperature), points.map(\.temperature))
        let stretched = CurvePoint.rebase(points, from: "22:00", until: "07:00", to: "21:00", until: "09:00")
        XCTAssertEqual(stretched.map(\.time), ["21:00", "02:20", "09:00"])
    }
    func testDraftValidationPreservesFractionsAndDisablesUnassignedCurves() {
        var draft = CurveDraft(curve: curve()); draft.points[0].temperature = 76.5
        XCTAssertNil(draft.validation); XCTAssertEqual(draft.payload.points["22:00"], 76.5)
        draft.days = CurveDays(); XCTAssertFalse(draft.payload.active)
        draft.points.append(draft.points[0]); XCTAssertNotNil(draft.validation)
        draft.points.removeLast(); draft.notes = String(repeating: "n", count: 1001); XCTAssertNotNil(draft.validation)
        draft.notes = ""; draft.points[0].temperature = .infinity; XCTAssertNotNil(draft.validation)
    }
    func testChangingRangePreservesShapeAndPresetUsesWallClock() {
        var draft = CurveDraft(curve: curve())
        draft.setBounds(coolest: 60, warmest: 84)
        XCTAssertEqual(draft.points.map(\.temperature), [76, 60, 84])
        draft.bedtime = "22:00"; draft.wake = "07:00"; draft.generate(.balanced)
        XCTAssertEqual(draft.ordered.first?.time, "21:15")
        XCTAssertEqual(draft.ordered.last?.time, "07:30")
        XCTAssertEqual(draft.points.map(\.temperature).min(), 60)
        XCTAssertEqual(draft.points.map(\.temperature).max(), 84)
    }
    func testCopyIsInactiveAndDoesNotCopyDayClaims() {
        let copied = CurveDraft(curve: curve(), copy: true)
        XCTAssertNil(copied.original); XCTAssertTrue(copied.days.isEmpty); XCTAssertFalse(copied.active)
        XCTAssertEqual(copied.name, "Weeknight copy"); XCTAssertEqual(copied.points.map(\.time), curve().ordered.map(\.time))
    }
    func testMovePreviewPreservesUnclaimedOtherSideDays() {
        var draft = CurveDraft(); draft.days = CurveDays(left: [.monday, .tuesday]); draft.active = true
        let moves = CurveMove.preview(draft, among: [curve()])
        XCTAssertEqual(moves, [CurveMove(name: "Weeknight", side: .left, days: [.monday, .tuesday], deactivated: false)])
        draft.days.right = [.friday]
        XCTAssertTrue(CurveMove.preview(draft, among: [curve()]).allSatisfy(\.deactivated))
        draft.active = false; XCTAssertTrue(CurveMove.preview(draft, among: [curve()]).isEmpty)
    }
    func testSchemaDiscoveryWorksForEmptyLibraryAndReferencedAlarmInput() throws {
        let schema = try JSONDecoder().decode(CoreAPIDocument.self, from: Data(Self.schema.utf8))
        XCTAssertNotNil(schema.operation("/curve-templates", method: "PUT"))
        XCTAssertTrue(schema.accepts("snoozeDuration", path: "/schedules/alarm", method: "POST"))
        XCTAssertTrue(schema.accepts("snoozeTaper", path: "/schedules/alarm", method: "POST"))
        XCTAssertFalse(schema.accepts("unknown", path: "/schedules/alarm", method: "POST"))
    }
    func testStaleCurveAndChangedDayClaimsBlockWrites() async {
        let client = CurveRecordingClient(curves: [curve()]); let model = CurveWorkspace(api: client)
        await model.refresh()
        var draft = CurveDraft(curve: curve()); draft.notes = "new"
        var changed = curve(); changed.notes = "Changed elsewhere"; await client.replace([changed])
        let saved = await model.save(draft, reviewed: []); XCTAssertFalse(saved)
        XCTAssertTrue(model.error?.contains("another device") == true)
        let writes = await client.puts; XCTAssertEqual(writes.count, 0)
        await model.refresh()
        var newDraft = CurveDraft(curve: curve(), copy: true); newDraft.active = true; newDraft.days.left = [.monday]
        let staleReview: [CurveMove] = []
        let overwritten = await model.save(newDraft, reviewed: staleReview); XCTAssertFalse(overwritten)
        XCTAssertTrue(model.error?.contains("review") == true)
    }
    func testAtomicLibrarySaveKeepsOtherSideClaimsAndDoesNotStartRunOnce() async throws {
        let client = DemoCurveClient(); let model = CurveWorkspace(api: client)
        await model.refresh()
        var draft = CurveDraft(curve: try XCTUnwrap(model.curves.first)); draft.name = "Edited"; draft.days.left = [.sunday]
        let saved = await model.save(draft, reviewed: model.moves(draft)); XCTAssertTrue(saved)
        let updated = try XCTUnwrap(model.curves.first { $0.id == 1 })
        XCTAssertEqual(updated.days?.right, DayOfWeek.weekdays); XCTAssertEqual(updated.days?.left, [.sunday])
        XCTAssertTrue(model.sessions.isEmpty)
        let removed = await model.delete(updated); XCTAssertTrue(removed)
        XCTAssertEqual(model.curves.map(\.id), [2])
    }
    func testSaveFailureKeepsLibraryAndDraftAvailable() async {
        let client = CurveRecordingClient(curves: [curve()]); let model = CurveWorkspace(api: client)
        await model.refresh(); await client.fail()
        var draft = CurveDraft(curve: curve()); draft.notes = "Unsaved note"
        let saved = await model.save(draft, reviewed: []); XCTAssertFalse(saved)
        XCTAssertTrue(model.loaded); XCTAssertEqual(model.curves.first?.notes, "Keep fractional readings")
        XCTAssertEqual(draft.notes, "Unsaved note"); XCTAssertNotNil(model.error)
    }
    func testRunOnceRebasesPreviewAndRejectsMoreThanFourteenHours() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z"))
        var draft = RunOnceDraft(curve: curve(), side: .left, now: now, timeZone: .gmt)
        XCTAssertEqual(draft.points.first?.time, "12:00"); XCTAssertEqual(draft.wake, "20:00")
        XCTAssertNil(draft.validation(now: now, timeZone: .gmt))
        draft.setWake("11:00"); XCTAssertNotNil(draft.validation(now: now, timeZone: .gmt))
        draft.setWake("20:00"); XCTAssertNil(draft.validation(now: now, timeZone: .gmt))
    }
    func testRESTUsesOwnedLibraryAndDoesNotRetryMutations() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CurveRequestProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreCurveClient(transport: CoreRESTClient(endpoint: URL(string: "https://curve-contract.invalid")!, session: session))
        let snapshot = try await client.library(); XCTAssertTrue(snapshot.supportsAssignments); XCTAssertTrue(snapshot.curves.isEmpty)
        var draft = CurveDraft(curve: curve()); draft.name = "Cold & calm"
        _ = try await client.put(draft.payload, assignments: true)
        try await client.delete(PodCurve(id: 1, name: "Cold & calm", bedtime: "22:00", wake: "07:00", points: [:], notes: ""))
        _ = try await client.start(side: .right, points: [RunOnceSetPoint(time: "22:00", temperature: 75)], wake: "07:00")
        try await client.cancel(.right)
    }
    static let schema = ##"{"paths":{"/curve-templates":{"put":{}},"/schedules/alarm":{"post":{"requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Alarm"}}}}}}},"components":{"schemas":{"Alarm":{"properties":{"snoozeDuration":{},"snoozeTaper":{}}}}}}"##
}

private actor CurveRecordingClient: CurveClient {
    var curves: [PodCurve]
    var puts: [CurvePut] = []
    var failing = false
    init(curves: [PodCurve]) { self.curves = curves }
    func replace(_ curves: [PodCurve]) { self.curves = curves }
    func fail() { failing = true }
    func library() async throws -> CurveLibrarySnapshot { CurveLibrarySnapshot(curves: curves, supportsAssignments: true) }
    func put(_ input: CurvePut, assignments: Bool) async throws -> CurveChange {
        puts.append(input)
        if failing { throw URLError(.notConnectedToInternet) }
        let curve = PodCurve(id: input.id ?? 100, name: input.name, bedtime: input.bedtime, wake: input.wake, points: input.points, notes: input.notes, endAction: input.endAction, days: input.days, active: input.active)
        curves.removeAll { $0.id == curve.id }; curves.append(curve)
        return CurveChange(curve: curve, moved: [])
    }
    func delete(_ curve: PodCurve) async throws { curves.removeAll { $0.id == curve.id } }
    func active(_ side: Side) async throws -> RunOnceSession? { nil }
    func start(side: Side, points: [RunOnceSetPoint], wake: String) async throws -> RunOnceStartResponse { RunOnceStartResponse(sessionId: 100, expiresAt: 0) }
    func cancel(_ side: Side) async throws {}
}

private final class CurveRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "curve-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }; body = data
        }
        let input = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let path = request.url!.path; var response = "{}"
        switch (request.httpMethod ?? "", path) {
        case ("GET", "/api/curve-templates"): response = "[]"
        case ("GET", "/api/openapi.json"):
            response = #"{"paths":{"/curve-templates":{"put":{}}}}"#
        case ("PUT", "/api/curve-templates"):
            XCTAssertEqual(input["name"] as? String, "Cold & calm")
            XCTAssertEqual((input["days"] as? [String: [String]])?["right"], ["friday"])
            XCTAssertEqual(input["endAction"] as? String, "maintain"); XCTAssertNil(input["alarm"])
            response = #"{"curve":{"id":1,"name":"Cold & calm","bedtime":"22:00","wake":"07:00","points":{"22:00":76,"07:00":80},"notes":"","days":{"left":["monday"],"right":["friday"]},"active":true,"endAction":"maintain"},"moved":[]}"#
        case ("DELETE", "/api/curve-templates"):
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Cold & calm")
        case ("POST", "/api/run-once/start"):
            XCTAssertEqual(input["side"] as? String, "right"); XCTAssertEqual(input["wakeTime"] as? String, "07:00")
            response = #"{"sessionId":100,"expiresAt":1793000000}"#
        case ("POST", "/api/run-once/cancel"): XCTAssertEqual(input["side"] as? String, "right")
        default: XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
