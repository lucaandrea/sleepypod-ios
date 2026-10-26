import XCTest
@testable import Sleepypod

@MainActor final class PersonalComfortRESTTests: XCTestCase {
    func testVersionedRoutesSideQueriesAndReviewNullRevision() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ComfortRequestProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CorePersonalComfortClient(transport: .init(endpoint: URL(string: "https://comfort-contract.invalid")!, session: session))
        let status = try await client.status(side: .left); try status.validate(side: .left)
        _ = try await client.configure(side: .left, config: status.state!.config)
        _ = try await client.feedback(side: .left, input: .init(date: "2026-10-25", comfort: "comfortable"))
        let reports = try await client.reports(side: .left); try reports.validate(side: .left)
        let detail = try await client.report(side: .left, id: reports.items[0].id, after: 2)
        try detail.validate(id: reports.items[0].id, after: 2)
        let input = ComfortReviewInput(side: .left, report: detail)
        let result = try await client.review(input); XCTAssertEqual(result.digest, input.digest); XCTAssertEqual(result.outcome, "needs_retest")
    }
}
private final class ComfortRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let example = try PersonalComfortExample.load(), path = request.url!.path, query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let input = (try? JSONSerialization.jsonObject(with: body())) as? [String: Any]
            let encoder = JSONEncoder()
            let data: Data
            let valid: Bool
            switch path {
            case "/api/v1/comfort":
                valid = request.httpMethod == "GET" && query == [.init(name: "side", value: "left")]
                data = try encoder.encode(example.status)
            case "/api/v1/comfort/configure":
                valid = request.httpMethod == "POST" && Set(input?.keys.map { $0 } ?? []) == ["side", "config"] && input?["side"] as? String == "left"
                data = try encoder.encode(example.status)
            case "/api/v1/comfort/feedback":
                let feedback = input?["feedback"] as? [String: String]
                valid = request.httpMethod == "POST" && Set(input?.keys.map { $0 } ?? []) == ["side", "feedback"] && input?["side"] as? String == "left" && feedback == ["date": "2026-10-25", "comfort": "comfortable"]
                data = try encoder.encode(example.status)
            case "/api/v1/comfort/reports":
                valid = request.httpMethod == "GET" && query == [.init(name: "side", value: "left")]
                data = try encoder.encode(ComfortNightList(apiVersion: 1, generatedAt: example.status.generatedAt, side: .left, items: [example.report.item], targetNights: 7, ownerConfirmedNights: 0, activationAvailable: false))
            case "/api/v1/comfort/report":
                valid = request.httpMethod == "GET" && query == [.init(name: "afterId", value: "2"), .init(name: "id", value: example.report.summary.id), .init(name: "side", value: "left")]
                let source = example.report
                data = try encoder.encode(ComfortNightDetail(summary: source.summary, review: nil, reviewCurrent: false, countsAsOwnerConfirmedNight: false, observations: source.observations.filter { $0.id > 2 }, nextAfterId: nil))
            case "/api/v1/comfort/report/review":
                valid = request.httpMethod == "POST" && input?["side"] as? String == "left" && input?["id"] as? String == example.report.summary.id
                    && input?["digest"] as? String == example.report.summary.digest && input?["expectedReviewId"] is NSNull && input?["outcome"] as? String == "needs_retest"
                    && input?["confirmedActualNight"] as? Bool == false && input?["note"] as? String == ""
                data = try encoder.encode(ComfortNightReview(id: 1, at: example.status.generatedAt, digest: example.report.summary.digest, outcome: "needs_retest", confirmedActualNight: false, note: ""))
            default: valid = false; data = Data()
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 422, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
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
