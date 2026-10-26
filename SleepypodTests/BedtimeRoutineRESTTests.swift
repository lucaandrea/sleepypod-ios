import XCTest
@testable import Sleepypod

@MainActor final class BedtimeRoutineRESTTests: XCTestCase {
    func testVersionedRoutineReadAndAtomicWritePreserveNullAndSchedulerReceipt() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RoutineRequestProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CoreBedtimeRoutineClient(transport: .init(endpoint: URL(string: "https://routine-contract.invalid")!, session: session))
        let book = try await client.routines(side: .left); try book.validate(side: .left)
        XCTAssertEqual(book.routines[0].draft.alarm?.snoozeDuration, 420); XCTAssertEqual(book.routines[0].draft.alarm?.snoozeTaper, 40)
        let changes = BedtimeRoutineChanges(side: .left, changes: [.init(dayOfWeek: .tuesday, expectedRevision: nil, replacement: .blank)])
        let receipt = try await client.replace(changes); try receipt.book.validate(side: .left)
        XCTAssertFalse(receipt.schedulerApplied); XCTAssertEqual(receipt.routines.count, 2)
        XCTAssertNil(receipt.routines[1].draft.alarm)
    }
}
private final class RoutineRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "bedtime-routine-example", withExtension: "json"))
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let valid: Bool, result: Any
            if request.httpMethod == "GET" {
                valid = request.url!.path == "/api/v1/routines" && query == [.init(name: "side", value: "left")]
                result = fixture["book"]!
            } else {
                let input = try JSONSerialization.jsonObject(with: body()) as! NSDictionary
                valid = request.url!.path == "/api/v1/routines" && request.httpMethod == "POST" && input == fixture["changes"] as! NSDictionary
                result = fixture["receipt"]!
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 422, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func body() -> Data {
        var result = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
        }
        return result
    }
    override func stopLoading() {}
}
