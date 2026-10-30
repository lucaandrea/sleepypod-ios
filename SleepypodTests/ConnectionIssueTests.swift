import XCTest
@testable import Sleepypod

final class ConnectionIssueTests: XCTestCase {
    func testNetworkFailuresDoNotClaimWiFiOrPermissionIsOff() {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost] {
            let issue = ConnectionIssue(APIError.networkError(URLError(code)))
            XCTAssertNotEqual(issue, .authentication)
            XCTAssertFalse(issue.detail.contains("not on Wi-Fi"))
            XCTAssertFalse(issue.detail.contains("has blocked"))
        }
        XCTAssertEqual(ConnectionIssue(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(ConnectionIssue(URLError(.cannotFindHost)), .unreachable)
    }
    func testAuthenticationAndMalformedRepliesRemainDistinct() {
        XCTAssertEqual(ConnectionIssue(APIError.invalidResponse(statusCode: 401)), .authentication)
        XCTAssertEqual(ConnectionIssue(APIError.invalidResponse(statusCode: 403)), .authentication)
        XCTAssertEqual(ConnectionIssue(APIError.invalidResponse(statusCode: 500)), .invalidResponse)
        XCTAssertEqual(ConnectionIssue(APIError.noBaseURL), .unconfigured)
    }
}
