import XCTest
@testable import Sleepypod

/// Explicit opt-in, read-only checks against the owner's controller. Credentials never enter output or fixtures.
@MainActor final class HomeFeedbackLiveTests: XCTestCase {
    private func connection() throws -> (SleepypodCoreClient, CoreRESTClient, URLSession) {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["POD_FEEDBACK_URL"], let endpoint = URL(string: address),
              let keyPath = environment["POD_FEEDBACK_KEY_FILE"] else {
            throw XCTSkip("Set TEST_RUNNER_POD_FEEDBACK_URL and TEST_RUNNER_POD_FEEDBACK_KEY_FILE for live read-only acceptance")
        }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIError.notSupported("The local controller key file is empty") }
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Authorization": "Bearer \(key)"]
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: FeedbackRejectRedirects(), delegateQueue: nil)
        return (.init(session: session, baseURL: endpoint), .init(endpoint: endpoint, session: session), session)
    }

    func testLiveSettingsSchedulesAndEveryCountedServiceDecode() async throws {
        let (api, _, session) = try connection(); defer { session.invalidateAndCancel() }
        _ = try await api.getSettings(); _ = try await api.getSchedules(); _ = try await api.getDeviceStatus()
        let status = StatusManager(api: api); await status.fetchAll()
        XCTAssertNotNil(status.serverStatus)
        XCTAssertGreaterThan(status.totalCount, 0)
        XCTAssertEqual(status.categories().flatMap(\.services).count, status.totalCount)
    }

    func testLiveFullHistoryMeetsTheRequestedMinimum() async throws {
        let (api, transport, session) = try connection(); defer { session.invalidateAndCancel() }
        let minimum = Int(ProcessInfo.processInfo.environment["POD_FEEDBACK_MINIMUM_RECORDS"] ?? "1") ?? 1
        let history = AnalysisHistoryWorkspace()
        await history.load(api: api, archive: CoreImportedHistoryClient(transport: transport))
        XCTAssertTrue(history.loaded); XCTAssertTrue(history.errors.isEmpty, history.errors.joined(separator: "; "))
        XCTAssertGreaterThanOrEqual(history.totalRecordCount, minimum, "The live controller must contain the preserved history")
        print("Live history counts: bed sessions=\(history.records.count), archived vitals=\(history.archive.vitals.count), movement=\(history.archive.movementCount), total=\(history.totalRecordCount)")
    }

    func testLiveBedSensorMeasurementsArePresentAndFresh() async throws {
        let (_, transport, session) = try connection(); defer { session.invalidateAndCancel() }
        let sensors = CoreSensorDiagnosticsClient(transport: transport)
        _ = try await sensors.occupancy()
        let latest = try await sensors.bed()
        let reading = try XCTUnwrap(latest)
        XCTAssertTrue(SensorObservation.fresh(reading.date, age: 120), "The sensor view needs fresh readings, not only a responding endpoint")
        let temperatures = [reading.leftOuterTemp, reading.leftCenterTemp, reading.leftInnerTemp,
                            reading.rightOuterTemp, reading.rightCenterTemp, reading.rightInnerTemp].compactMap { $0 }
        XCTAssertEqual(temperatures.count, 6)
        XCTAssertTrue(temperatures.allSatisfy { $0.isFinite && (-10...70).contains($0) })
        _ = try await sensors.freezer(); _ = try await sensors.water()
    }
}

private final class FeedbackRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
