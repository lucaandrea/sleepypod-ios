import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class NativeSleepEvidenceTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1_793_722_800) // Fixed clock, independent of the test runner's day.
    private var range: ClosedRange<Date> { end.addingTimeInterval(-30 * 86400)...end }
    private func record(_ id: Int, start: Double, end: Double?, exits: Int = 0, intervals: String? = nil) -> SleepRecord {
        var result = SleepRecord(id: id, side: "right", enteredBed: Date(timeIntervalSince1970: start),
                                 leftBed: end.map { Date(timeIntervalSince1970: $0) }, timesExitedBed: exits)
        result.presentIntervals = intervals; return result
    }
    private func calculate(_ records: [SleepRecord], vitals: VitalsSummary? = nil) throws -> NativePodEvidence {
        try NativeSleepEvidence.calculate(records: records, vitals: vitals, side: .right, days: 30,
                                          zone: TimeZone(identifier: "America/Los_Angeles")!, range: range)
    }
    func testDisjointAndOverlappingPresenceUsesUnionAndWakeDatesNotSleepDuration() throws {
        let start = end.addingTimeInterval(-86400).timeIntervalSince1970
        let records = [record(1, start: start, end: start + 10_800, exits: 1,
                              intervals: "[[\(start),\(start + 3600)],[\(start + 7200),\(start + 10800)]]"),
                       record(2, start: start + 600, end: start + 3000)]
        let result = try calculate(records)
        XCTAssertTrue(result.hasObservations)
        XCTAssertTrue(result.facts.first { $0.id == "pod.presence" }!.text.contains("120 minutes"))
        XCTAssertTrue(result.summary.contains("120 average")); XCTAssertTrue(result.summary.contains("1 recorded wake dates"))
        XCTAssertTrue(result.summary.contains("not measured sleep")); XCTAssertFalse(result.facts.contains { $0.text.contains("quality score") })
    }
    func testMalformedIntervalsOngoingAndStuckRecordsStayUnknownInsteadOfZeroSleep() throws {
        let start = end.addingTimeInterval(-86400).timeIntervalSince1970
        let records = [record(1, start: start, end: start + 3600, intervals: "broken"),
                       record(2, start: start, end: nil), record(3, start: start, end: start + 18 * 3600),
                       record(4, start: start, end: start + 3600, exits: 1, intervals: "[[null,\(start + 1800)]]")]
        let result = try calculate(records)
        XCTAssertFalse(result.hasObservations); XCTAssertTrue(result.summary.contains("does not establish zero sleep"))
        XCTAssertFalse(result.facts.contains { $0.id == "pod.presence" })
        XCTAssertTrue(result.facts.first { $0.id == "pod.coverage" }!.text.contains("4 records"))
    }
    func testWrongSideBadTimeAndDuplicateIDsFailRatherThanBecomingAnEmptyReport() {
        let start = end.addingTimeInterval(-86400).timeIntervalSince1970
        var wrong = record(1, start: start, end: start + 3600); wrong.side = "left"
        XCTAssertThrowsError(try calculate([wrong]))
        XCTAssertThrowsError(try calculate([record(1, start: start, end: start - 100)]))
        let valid = record(1, start: start, end: start + 3600)
        XCTAssertThrowsError(try calculate([valid, valid]))
    }
    func testBoundaryPresenceIsClippedAndEmptyIsNotZeroMeasuredSleep() throws {
        let start = range.lowerBound.timeIntervalSince1970
        let result = try calculate([record(1, start: start - 3600, end: start + 3600)])
        XCTAssertTrue(result.facts.first { $0.id == "pod.presence" }!.text.contains("60 minutes"))
        let empty = try calculate([])
        XCTAssertFalse(empty.hasObservations); XCTAssertTrue(empty.summary.contains("no eligible"))
    }
    func testRecordedSDNNIsQualifiedAndLegacyMixedOrOtherDefinitionsAreNotRelabeled() throws {
        let base = "\"interpretation\":\"original_observations\",\"configurationCount\":2,\"unknownConfigurationRows\":1,\"hrvRows\":8,\"hrvDefinitionCount\":1,\"unknownHrvRows\":0"
        for metric in ["hrv_sdnn", "hrv_custom"] {
            let json = "{\"avgHeartRate\":58,\"avgBreathingRate\":13,\"avgHRV\":45,\"recordCount\":10,\"provenance\":{\(base),\"hrvMetricId\":\"\(metric)\",\"hrvAggregation\":\"single_definition\"}}"
            let vitals = try JSONDecoder().decode(VitalsSummary.self, from: Data(json.utf8))
            let result = try calculate([], vitals: vitals)
            XCTAssertTrue(result.hasObservations)
            XCTAssertEqual(result.facts.contains { $0.id == "pod.hrv" }, metric == "hrv_sdnn")
            XCTAssertTrue(result.facts.first { $0.id == "pod.processing" }!.text.contains("Mixed or unknown"))
            XCTAssertTrue(result.facts.first { $0.id == "pod.heart" }!.text.contains("not limited to sleep"))
        }
        let legacy = VitalsSummary(avgHeartRate: 58, avgHRV: 45)
        XCTAssertFalse(try calculate([], vitals: legacy).facts.contains { $0.id == "pod.hrv" })
    }
    func testActualCoreProvenanceCasesKeepHRVDefinitionsSeparate() throws {
        struct Fixture: Decodable { let synthetic: Bool; let cases: [String: VitalSummaryProvenance] }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "vital-summary-example", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertTrue(fixture.synthetic); XCTAssertEqual(fixture.cases.count, 7)
        for (name, provenance) in fixture.cases {
            XCTAssertEqual(provenance.hasKnownSDNN, ["recorded", "mixedConfiguration"].contains(name))
            let summary = VitalsSummary(avgHRV: 45, recordCount: 10, provenance: provenance)
            XCTAssertEqual(NativeVitalEvidence.facts(summary).contains { $0.id == "pod.hrv" }, provenance.hasKnownSDNN)
        }
    }
    func testServiceUsesFrozenSideCalendarRangeAndToleratesOnlyOptionalVitalsFailure() async throws {
        let probe = EvidenceProbe(), service = NativeSleepEvidence(client: { EvidenceClient(probe) }, owner: { ["owner"] }, now: { self.end })
        let result = try await service.load(side: .right, days: 30)
        XCTAssertEqual(result.side, "right"); XCTAssertEqual(result.days, 30)
        XCTAssertEqual(probe.recordSides, [.right]); XCTAssertEqual(probe.vitalSides, [.right])
        XCTAssertEqual(probe.recordsStart, result.start.addingTimeInterval(-16 * 3600))
        XCTAssertEqual(probe.vitalsStart, result.start); XCTAssertEqual(probe.recordsEnd, end)
        XCTAssertFalse(result.hasObservations)
        let calls = probe.recordSides.count
        do { _ = try await service.load(side: .right, days: 31); XCTFail("Unsupported range") } catch {}
        XCTAssertEqual(probe.recordSides.count, calls)
    }
    func testOwnerChangeAndCancellationAfterRecordsStopBeforeVitalsOrPublication() async throws {
        for cancelled in [false, true] {
            let probe = EvidenceProbe(); probe.hold = true
            let service = NativeSleepEvidence(client: { EvidenceClient(probe) }, owner: { probe.owner }, now: { self.end })
            let operation = Task { try await service.load(side: .right, days: 7) }
            await probe.waitHeld()
            if cancelled { operation.cancel() } else { probe.owner = ["other"] }
            probe.release()
            do { _ = try await operation.value; XCTFail("Stale read cannot publish") } catch {}
            XCTAssertTrue(probe.vitalSides.isEmpty)
        }
    }
}
@MainActor private final class EvidenceProbe {
    var recordSides: [Side?] = [], vitalSides: [Side?] = []
    var recordsStart: Date?, recordsEnd: Date?, vitalsStart: Date?
    var owner = ["owner"], hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func records(_ side: Side?, start: Date?, end: Date?) async -> [SleepRecord] {
        recordSides.append(side); recordsStart = start; recordsEnd = end
        if hold { await withCheckedContinuation { continuation = $0 } }
        return []
    }
    func vitals(_ side: Side?, start: Date?) throws -> VitalsSummary {
        vitalSides.append(side); vitalsStart = start; throw URLError(.notConnectedToInternet)
    }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class EvidenceClient: MockAPIClient, @unchecked Sendable {
    let probe: EvidenceProbe
    init(_ probe: EvidenceProbe) { self.probe = probe; super.init() }
    override func getSettings() async throws -> PodSettings { try await MockClient().getSettings() }
    override func getSleepRecords(side: Side?, start: Date?, end: Date?) async throws -> [SleepRecord] { await probe.records(side, start: start, end: end) }
    override func getVitalsSummary(side: Side?, start: Date?, end: Date?) async throws -> VitalsSummary { try await probe.vitals(side, start: start) }
}
