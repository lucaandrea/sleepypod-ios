import XCTest
@testable import Sleepypod

@MainActor final class WatchReferenceTests: XCTestCase {
    private func client(_ host: String = "watch-modern.invalid") -> CoreWatchReferenceClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WatchReferenceProtocol.self]
        return CoreWatchReferenceClient(transport: CoreRESTClient(endpoint: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration)))
    }
    private var window: DateInterval { DateInterval(start: Date(timeIntervalSince1970: 1792882800), duration: 8 * 3600) }
    func testAllReferenceMetricsRemainSeparateAndPreserveStageDefinitions() async throws {
        let result = try await client().load(side: .right, window: window)
        XCTAssertTrue(result.extendedMetrics); XCTAssertEqual(result.heartRate.count, 1)
        XCTAssertEqual(result.breathing.first?.value, 14); XCTAssertEqual(result.hrv.first?.value, 45)
        XCTAssertEqual(result.stages.map(\.stage), [.rem]); XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.csv.contains("apple_watch,hrv_sdnn,")); XCTAssertTrue(result.csv.contains("apple_watch,sleep_stage,"))
        let comparison = result.comparison(epochs: [], vitals: [])
        XCTAssertEqual(comparison.watchHRV.first?.value, 45); XCTAssertNil(comparison.hrv.ours)
    }
    func testOlderControllerKeepsHeartRateAndStagesWithoutInventingExtendedSamples() async throws {
        let result = try await client("watch-legacy.invalid").load(side: .right, window: window)
        XCTAssertFalse(result.extendedMetrics); XCTAssertEqual(result.heartRate.count, 1)
        XCTAssertEqual(result.stages.count, 1); XCTAssertTrue(result.hrv.isEmpty); XCTAssertTrue(result.breathing.isEmpty)
    }
    func testInvalidReferenceDatesAndUnknownStagesAreNotTurnedIntoEpochZero() throws {
        let sample = try JSONDecoder().decode(ReferenceMetricSample.self, from: Data(#"{"timestamp":"invalid","value":40}"#.utf8))
        XCTAssertNil(sample.reading)
        let stage = try JSONDecoder().decode(ReferenceStage.self, from: Data(#"{"id":1,"side":"right","source":"apple_watch","start":"2026-10-25T01:00:00Z","end":"2026-10-25T01:30:00Z","stage":"unknown"}"#.utf8))
        XCTAssertNil(stage.sample)
    }
    func testImportTransportUsesRawFileBodyAndAcceptsLegacyResult() async throws {
        let file = try fixtureFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try await client().upload(file: file, side: .right, period: .quarter, progress: { _ in })
        XCTAssertEqual(result.vitals, 2); XCTAssertEqual(result.stages, 3); XCTAssertNil(result.hrv)
    }
    func testImportHTTPFailureDoesNotBecomeASuccessReceipt() async throws {
        let file = try fixtureFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        do { _ = try await client("watch-error.invalid").upload(file: file, side: .right, period: .quarter, progress: { _ in }); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rejected export")) }
    }
    func testPreparedFileIsPrivateSnapshotAndCleanupRemovesIt() async throws {
        let file = try fixtureFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = WatchImportWorkspace(side: .right, client: DemoWatchReferenceClient())
        await model.prepare(file)
        let copy = try XCTUnwrap(model.file)
        XCTAssertNotEqual(copy.url, file); XCTAssertEqual(copy.bytes, 7)
        try Data("changed".utf8).write(to: file)
        XCTAssertEqual(try Data(contentsOf: copy.url), Data("fixture".utf8))
        model.cleanup(); XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path)); XCTAssertNil(model.file)
    }
    func testImportRejectsWrongTypeEmptyAndOversizedFiles() throws {
        let file = try fixtureFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertThrowsError(try WatchExportFile.validate(file.deletingPathExtension().appendingPathExtension("txt")))
        try Data().write(to: file); XCTAssertThrowsError(try WatchExportFile.validate(file))
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(WatchExportFile.maximumBytes + 1))
        XCTAssertThrowsError(try WatchExportFile.validate(file))
    }
    func testMixedPodProcessingRunsDoNotProduceComparisonAverages() {
        let date = window.start
        var first = VitalsRecord(id: 1, heartRate: 60, hrv: 40, breathingRate: 14, date: date)
        var second = VitalsRecord(id: 2, heartRate: 70, hrv: 50, breathingRate: 16, date: date.addingTimeInterval(60))
        first.processingRunId = "old"; second.processingRunId = "new"
        let watch = [WatchComparison.Reading(date: date, value: 62), .init(date: date.addingTimeInterval(60), value: 72)]
        let result = WatchComparison.build(epochs: [], vitals: [first, second], watchStages: [], watchHeartRate: watch, watchHRV: [], watchBreathing: [])
        XCTAssertNil(result.heartRateBias); XCTAssertNil(result.heartRateError); XCTAssertNil(result.hrv.ours); XCTAssertNil(result.breathing.ours)
    }
    private func fixtureFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("export.xml"); try Data("fixture".utf8).write(to: file); return file
    }
}

private final class WatchReferenceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("watch-") == true && request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var status = 200
        var body = "[]"
        switch url.path {
        case "/api/openapi.json": body = url.host == "watch-legacy.invalid" ? #"{"paths":{}}"# : #"{"paths":{"/biometrics/reference-samples":{"get":{}}}}"#
        case "/api/biometrics/reference-vitals":
            XCTAssertEqual(query["side"], "right"); XCTAssertEqual(query["limit"], "20000"); XCTAssertNotNil(query["startDate"]); XCTAssertNotNil(query["endDate"])
            body = #"[{"id":1,"side":"right","source":"apple_watch","timestamp":"2026-10-25T01:00:00.000Z","heartRate":61}]"#
        case "/api/biometrics/reference-stages":
            body = #"[{"id":1,"side":"right","source":"apple_watch","start":"2026-10-25T01:00:00Z","end":"2026-10-25T01:30:00Z","stage":"rem"}]"#
        case "/api/biometrics/reference-samples":
            XCTAssertNotEqual(url.host, "watch-legacy.invalid")
            body = "[{\"timestamp\":\"2026-10-25T01:00:00Z\",\"value\":\(query["metric"] == "hrv_sdnn" ? 45 : 14)}]"
        case "/api/biometrics/watch-upload":
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(query["side"], "right"); XCTAssertEqual(query["days"], "90")
            if url.host == "watch-error.invalid" { status = 400; body = #"{"error":"rejected export"}"# }
            else { body = #"{"stages":3,"vitals":2,"matchedStages":4,"matchedVitals":5,"rejectedStageBatches":0}"# }
        default: XCTFail("Unexpected reference request: \(url.path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
