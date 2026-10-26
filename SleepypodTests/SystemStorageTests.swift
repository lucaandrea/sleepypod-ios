import XCTest
@testable import Sleepypod

@MainActor final class SystemStorageTests: XCTestCase {
    func testBackupExclusionAndMissingCapacityStayExplicit() async {
        let report = await DemoSystemStorageClient().report()
        XCTAssertEqual(report.selected(includeBackups: false).count, 2)
        XCTAssertEqual(report.selected(includeBackups: true).count, 3)
        XCTAssertEqual(report.backupCount, 1)
        XCTAssertEqual(SystemStorage.bytes(.infinity), "Unknown")
        XCTAssertEqual(SystemStorage.bytes(-1), "Unknown")
        XCTAssertNotEqual(SystemStorage.bytes(0), "Unknown")
        XCTAssertEqual(report.reclaimable.items.first?.shortPath, "sleepypod-releases/demo-old")
    }
    func testExpiredAndChangedCandidatesCannotBeDeleted() async {
        let client = StorageFixtureClient()
        let model = SystemStorageWorkspace(client: client)
        await model.load()
        let original = model.selection(includeBackups: false)!
        XCTAssertNil(model.selection(includeBackups: false, now: .now.addingTimeInterval(91)))
        await client.removeLeftovers()
        await model.load()
        await model.clean(original)
        let calls = await client.cleanupCalls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(model.actionError?.contains("changed") == true)
    }
    func testFailedReadKeepsReportButDisablesCleanup() async {
        let client = StorageFixtureClient()
        let model = SystemStorageWorkspace(client: client)
        await model.load()
        await client.failRead()
        await model.load()
        XCTAssertNotNil(model.report); XCTAssertNotNil(model.error)
        XCTAssertNil(model.selection(includeBackups: true))
    }
    func testCleanupFailureRequiresReadbackAndNeverShowsSuccess() async {
        let client = StorageFixtureClient(failCleanup: true)
        let model = SystemStorageWorkspace(client: client)
        await model.load()
        let selection = model.selection(includeBackups: false)!
        await model.clean(selection)
        XCTAssertNil(model.result); XCTAssertTrue(model.mustReload)
        XCTAssertTrue(model.actionError?.contains("not confirmed") == true)
        await model.clean(selection)
        let calls = await client.cleanupCalls
        XCTAssertEqual(calls, 1)
        await model.load()
        XCTAssertNotNil(model.selection(includeBackups: false))
    }
    func testSuccessfulCleanupReadsFreshReportAndKeepsExcludedBackups() async {
        let model = SystemStorageWorkspace(client: DemoSystemStorageClient())
        await model.load()
        await model.clean(model.selection(includeBackups: false)!)
        XCTAssertEqual(model.result?.removed, 2)
        XCTAssertEqual(model.result?.freedBytes, 360_000_000)
        XCTAssertNil(model.selection(includeBackups: false))
        XCTAssertEqual(model.selection(includeBackups: true)?.items.count, 1)
    }
    func testExactReportAndCleanupRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StorageFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CoreSystemStorageClient(transport: .init(endpoint: URL(string: "https://storage-test.invalid")!, session: session))
        let report = try await client.report()
        XCTAssertFalse(report.reclaimable.available)
        XCTAssertNil(report.rawHistory.days)
        let result = try await client.clean(includeBackups: false)
        XCTAssertEqual(result.removed, 2); XCTAssertEqual(result.freedBytes, 1000)
    }
}
private actor StorageFixtureClient: SystemStorageClient {
    private let demo = DemoSystemStorageClient()
    private var failedRead = false
    private let failCleanup: Bool
    private(set) var cleanupCalls = 0
    init(failCleanup: Bool = false) { self.failCleanup = failCleanup }
    func removeLeftovers() async { _ = await demo.clean(includeBackups: false) }
    func failRead() { failedRead = true }
    func report() async throws -> SystemStorage { if failedRead { throw APIError.noBaseURL }; return await demo.report() }
    func clean(includeBackups: Bool) async throws -> StorageCleanupResult {
        cleanupCalls += 1
        if failCleanup { throw APIError.noBaseURL }
        return await demo.clean(includeBackups: includeBackups)
    }
}
private final class StorageFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "storage-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let json: String
            switch url.path {
            case "/api/system/storage":
                XCTAssertEqual(request.httpMethod, "GET")
                json = #"{"persistent":{"totalBytes":0,"usedBytes":0,"availableBytes":0,"usedPercent":0},"prunerTargetPercent":75,"segments":[],"rawHistory":{"fileCount":0,"oldest":null,"newest":null,"days":null},"reclaimable":{"available":false,"totalBytes":0,"items":[]}}"#
            case "/api/system/storage/free":
                XCTAssertEqual(request.httpMethod, "POST")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                XCTAssertEqual(try JSONDecoder().decode([String: Bool].self, from: data), ["includeDbBackups": false])
                json = #"{"freedBytes":1000,"removed":2}"#
            default: XCTFail("Unexpected request \(url.path)"); throw APIError.noBaseURL
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
