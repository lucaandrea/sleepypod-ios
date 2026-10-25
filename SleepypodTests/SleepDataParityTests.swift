import XCTest
import HealthKit
@testable import Sleepypod

@MainActor final class SleepDataParityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    func testCalendarKeepsDSTAndAfterMidnightSleepOnPreviousNight() throws {
        let calendar = SleepCalendar.calendar(timeZone: "America/Los_Angeles")
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 3)))
        let night = SleepCalendar.nightDate(for: morning, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: night), 31)
        let window = BiometricRange.night.window(through: night, calendar: calendar)
        XCTAssertEqual(window.duration, 25 * 3600)
        let spring = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 18)))
        XCTAssertEqual(BiometricRange.night.window(through: spring, calendar: calendar).duration, 23 * 3600)
    }
    func testOpenSleepRecordRoundTripsWithoutFakeWakeDate() throws {
        let record = SleepRecord(id: 1, side: "left", enteredBed: base, leftBed: nil)
        let decoded = try JSONDecoder().decode(SleepRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record); XCTAssertNil(decoded.completedAt); XCTAssertTrue(decoded.isOngoing)
        XCTAssertTrue(SleepCSV.sleep([record]).contains(",,0,0"))
        var draft = SleepRecordDraft(record); XCTAssertNotNil(draft.validation)
        draft.hasWake = true; draft.wake = base.addingTimeInterval(8 * 3600); XCTAssertNil(draft.validation)
        draft.wake = base; XCTAssertNotNil(draft.validation)
    }
    func testNightExportsIncludeMorningNapsAndEntireWakeInterval() throws {
        let calendar = SleepCalendar.calendar(timeZone: "America/Los_Angeles")
        func date(_ day: Int, _ hour: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)))
        }
        let nights = SleepCalendar.nightWindow(from: try date(1, 0), until: try date(2, 0), calendar: calendar)
        XCTAssertEqual(nights.start, try date(1, 6)); XCTAssertEqual(nights.end, try date(2, 6))
        let nap = SleepRecord(id: 1, side: "left", enteredBed: try date(1, 10), leftBed: try date(1, 11))
        let night = SleepRecord(id: 2, side: "left", enteredBed: try date(1, 23), leftBed: try date(2, 9))
        let exported = SleepCalendar.exportWindow(nights: nights, records: [nap, night])
        XCTAssertEqual(exported.start, try date(1, 6)); XCTAssertEqual(exported.end, try date(2, 9))
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: try date(1, 0)))
        let transition = SleepCalendar.nightWindow(from: previousDay, until: try date(1, 0), calendar: calendar)
        XCTAssertEqual(transition.duration, 25 * 3600)
    }
    func testCSVPreservesMissingValuesSourceAndEscapesMetadata() {
        var record = VitalsRecord(id: 7, heartRate: 61.5, hrv: nil, breathingRate: .infinity, date: base)
        record.provenance = VitalProvenance(interpretation: "original_observation", status: "recorded", processingRunId: "=SUM(1,2)", configurationHash: "hash", hrvMetricId: "window_ibi_variability_v1")
        let csv = SleepCSV.vitals([record])
        XCTAssertTrue(csv.contains(",61.5,,,original_observation,"))
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\"")); XCTAssertFalse(csv.contains("inf"))
        XCTAssertTrue(csv.contains("window_ibi_variability_v1"))
        XCTAssertEqual(SleepCSV.cell("a\"b,c"), "\"a\"\"b,c\"")
    }
    func testLimitedRangeIsSplitAndBoundaryRowsAreDeduplicated() async throws {
        let all = (0..<21).map { VitalsRecord(id: $0, heartRate: 60, date: base.addingTimeInterval(Double($0) * 60)) }
        let result = try await MetricRangeLoader.load(start: base, end: base.addingTimeInterval(20 * 60), limit: 5) { start, end in
            Array(all.filter { $0.date >= start && $0.date <= end }.reversed().prefix(5))
        }
        XCTAssertEqual(Set(result.map(\.id)), Set(0..<21)); XCTAssertEqual(result.count, 21)
    }
    func testUnresolvableSaturatedTimestampReportsIncompleteData() async {
        do {
            let _: [VitalsRecord] = try await MetricRangeLoader.load(start: base, end: base.addingTimeInterval(1), limit: 2) { _, _ in [VitalsRecord(id: 1), VitalsRecord(id: 2)] }
            XCTFail("A capped response must not be reported as complete")
        } catch { XCTAssertTrue(error.localizedDescription.contains("completely")) }
    }
    func testPlotsDoNotBridgeMissingValuesOrProcessingChanges() {
        var records = (0..<6).map { VitalsRecord(id: $0, heartRate: Double(60 + $0), date: base.addingTimeInterval(Double($0) * 60)) }
        records[2].heartRate = nil; records[4].processingRunId = "new"; records[5].processingRunId = "new"
        let plot = BiometricPlot(metric: .heartRate, records: records)
        XCTAssertEqual(plot.points.map(\.segment), [0, 0, 1, 2, 2])
        XCTAssertEqual(plot.points[0].smooth, 60.5); XCTAssertTrue(plot.mixedSources); XCTAssertNil(plot.stats)
    }
    func testQuartilesAndDisplaySamplingRetainExtrema() {
        let records = (0..<4000).map { VitalsRecord(id: $0, heartRate: $0 == 123 ? 190 : Double($0 % 80 + 40), date: base.addingTimeInterval(Double($0) * 60)) }
        let plot = BiometricPlot(metric: .heartRate, records: records)
        let display = plot.displayPoints(in: base...records.last!.date)
        XCTAssertLessThanOrEqual(display.count, 1500); XCTAssertTrue(display.contains { $0.value == 190 })
        XCTAssertEqual(display.first?.id, 0); XCTAssertEqual(display.last?.id, 3999)
        XCTAssertNotNil(plot.stats)
    }
    func testViewportZoomPanAndRangeStayBounded() {
        var viewport = BiometricViewport(start: base, end: base.addingTimeInterval(8 * 3600))
        viewport.scale(2); XCTAssertEqual(viewport.zoom, 2)
        viewport.pan(-10); XCTAssertEqual(viewport.window.lowerBound, base)
        viewport.pan(10); XCTAssertEqual(viewport.window.upperBound, viewport.full.upperBound)
        viewport.scale(100); XCTAssertEqual(viewport.zoom, 16)
        viewport.reset(); XCTAssertEqual(viewport.window, viewport.full)
    }
    func testHealthOnlyWritesExplicitSDNNAndKeepsOtherVitals() {
        let record = SleepRecord(id: 1, side: "left", enteredBed: base, leftBed: base.addingTimeInterval(3600))
        var vital = VitalsRecord(id: 1, heartRate: 60, hrv: 40, breathingRate: 14, date: base)
        func quantities(_ vital: VitalsRecord) -> [HKQuantitySample] {
            HealthSyncService.samples(record: record, epochs: [], podID: "test", preferences: .init(), vitals: [vital]).compactMap { $0 as? HKQuantitySample }
        }
        XCTAssertEqual(quantities(vital).count, 2)
        vital.provenance = VitalProvenance(interpretation: "original_observation", status: "recorded", processingRunId: "r", configurationHash: "h", hrvMetricId: "window_ibi_variability_v1")
        XCTAssertEqual(quantities(vital).count, 2)
        vital.provenance?.hrvMetricId = "hrv_sdnn"
        XCTAssertEqual(quantities(vital).filter { $0.quantityType.identifier == HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue }.count, 1)
    }
    func testSleepEditsPersistInDemoAndStaleDraftCannotOverwrite() async throws {
        let client = MockClient(); let metrics = MetricsManager(api: client)
        let initial = try await client.getSleepRecords(side: .left)
        let original = try XCTUnwrap(initial.last)
        var draft = SleepRecordDraft(original); draft.wake = original.leftBedDate.addingTimeInterval(60)
        let saved = await metrics.change(draft); XCTAssertTrue(saved)
        let stale = await metrics.change(draft); XCTAssertFalse(stale); XCTAssertTrue(metrics.mutationError?.contains("another device") == true)
        let updated = try await client.getSleepRecords(side: .left)
        let changed = try XCTUnwrap(updated.first { $0.id == original.id })
        XCTAssertEqual(changed.leftBedDate, draft.wake)
        let deleted = await metrics.change(SleepRecordDraft(changed), deleting: true); XCTAssertTrue(deleted)
        let remaining = try await client.getSleepRecords(side: .left); XCTAssertFalse(remaining.contains { $0.id == original.id })
    }
    func testExportWritesSeparateFilesAndCleansUp() throws {
        let model = SleepExportWorkspace(api: DemoRawDataClient())
        model.csv([(name: "vitals.csv", text: "a,b\r\n1,2\r\n"), (name: "sleep.csv", text: "a\r\n3\r\n")])
        XCTAssertEqual(model.shares.count, 2)
        let first = try XCTUnwrap(model.shares.first)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "a,b\r\n1,2\r\n")
        model.cleanup(); XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }
    func testCoreMetricTransportPreservesRangeAndProvenance() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SleepRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SleepypodCoreClient(session: session, baseURL: URL(string: "https://sleep-contract.invalid")!)
        let vitals = try await client.getVitals(side: .right, start: base, end: base.addingTimeInterval(3600))
        XCTAssertEqual(vitals.first?.hrvMetricID, "window_ibi_variability_v1")
        XCTAssertEqual(vitals.first?.sourceKey, "run-1")
        _ = try await client.getSleepRecords(side: .right, start: base, end: base.addingTimeInterval(3600))
        _ = try await client.getMovement(side: .right, start: base, end: base.addingTimeInterval(3600))
    }
    func testRawDeleteReportsLogicalFailureEvenWhenHTTPIsSuccessful() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SleepRequestProtocol.self]
        let client = CoreRawDataClient(transport: CoreRESTClient(endpoint: URL(string: "https://sleep-contract.invalid")!, session: URLSession(configuration: configuration)))
        do {
            try await client.delete(RawSensorFile(name: "00001054.RAW", sizeBytes: 1, modifiedAt: base.ISO8601Format()))
            XCTFail("HTTP 200 with deleted=false must not be treated as deletion")
        } catch { XCTAssertTrue(error.localizedDescription.contains("active")) }
    }
    func testRawFilesCannotDeleteActiveOrEscapeFilename() async throws {
        let client = DemoRawDataClient(); let files = await client.files()
        do { try await client.delete(files[0]); XCTFail("Active file must be preserved") } catch {}
        try await client.delete(files[1]); let remaining = await client.files(); XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(RawSensorFile.validName("../secret.RAW")); XCTAssertTrue(RawSensorFile.validName("00001054.RAW"))
    }
    func testPipelineStallRequiresCredibleAvailableOccupancyAndOldReadings() {
        func status(available: Bool = true, occupied: Bool = true, credibility: String = "occupied", latest: Date? = nil) -> BiometricsLiveStatus {
            let presence = BiometricPresence(occupied: occupied, available: available, classification: "person", movement: .init(active: true, peakScore: 220), level: .init(deviation: 2, ageMs: 1000))
            return BiometricsLiveStatus(sides: ["left": presence], credibility: ["left": credibility], latest: latest, checked: base)
        }
        XCTAssertTrue(status().stalled(.left, now: base))
        XCTAssertTrue(status(latest: base.addingTimeInterval(-901)).stalled(.left, now: base))
        XCTAssertFalse(status(latest: base.addingTimeInterval(-900)).stalled(.left, now: base))
        XCTAssertFalse(status(available: false).stalled(.left, now: base))
        XCTAssertFalse(status(occupied: false).stalled(.left, now: base))
        XCTAssertFalse(status(credibility: "suspect").stalled(.left, now: base))
        XCTAssertFalse(status(credibility: "unknown").stalled(.left, now: base))
    }
    func testMovementTransportUsesInBedBucketsAndHourlyRate() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SleepRequestProtocol.self]
        let client = CoreBiometricsContextClient(transport: CoreRESTClient(endpoint: URL(string: "https://sleep-contract.invalid")!, session: URLSession(configuration: configuration)))
        let buckets = try await client.movement(side: .right, window: DateInterval(start: base, duration: 8 * 3600))
        XCTAssertEqual(buckets.count, 1); XCTAssertEqual(buckets.first?.eventsPerHour, 24)
        XCTAssertEqual(buckets.first?.sampleCount, 5); XCTAssertNotNil(buckets.first?.date)
    }
}

private final class SleepRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sleep-contract.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var response = ""
        if url.path == "/api/biometrics/movement/buckets" {
            let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(fields["side"], "right"); XCTAssertEqual(fields["bucketSeconds"], "300"); XCTAssertEqual(fields["limit"], "10000")
            XCTAssertNotNil(fields["startDate"]); XCTAssertNotNil(fields["endDate"])
            response = #"[{"side":"right","bucketStart":"2026-10-25T01:00:00Z","totalMovement":450,"eventCount":2,"sampleCount":5}]"#
        } else if url.path == "/api/raw/files/delete" {
            XCTAssertEqual(request.httpMethod, "POST")
            response = #"{"deleted":false,"message":"Cannot delete the active sensor file"}"#
        } else {
            XCTAssertEqual(request.httpMethod, "GET")
            let input = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "input" }?.value ?? "{}"
            let envelope = (try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]) ?? [:]
            let fields = envelope["json"] as? [String: Any] ?? [:]
            XCTAssertEqual(fields["side"] as? String, "right")
            XCTAssertNotNil(fields["startDate"]); XCTAssertNotNil(fields["endDate"])
            XCTAssertEqual((envelope["meta"] as? [String: [String: [String]]])?["values"]?["startDate"], ["Date"])
            var records = "[]"
            switch url.lastPathComponent {
            case "biometrics.getVitals":
                XCTAssertEqual(fields["limit"] as? Int, 20000)
                records = #"[{"id":1,"side":"right","timestamp":"2026-09-21T14:13:20Z","heartRate":60,"hrv":42,"breathingRate":14,"provenance":{"interpretation":"original_observation","status":"recorded","processingRunId":"run-1","configurationHash":"hash","hrvMetricId":"window_ibi_variability_v1"}}]"#
            case "biometrics.getSleepRecords": XCTAssertEqual(fields["limit"] as? Int, 100)
            case "biometrics.getMovement": XCTAssertEqual(fields["limit"] as? Int, 1000)
            default: XCTFail("Unexpected metrics request: \(url.path)")
            }
            response = "{\"result\":{\"data\":{\"json\":\(records)}}}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
