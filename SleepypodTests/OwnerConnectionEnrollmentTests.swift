import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class OwnerConnectionEnrollmentTests: XCTestCase {
    private let key = "synthetic-candidate-credential-not-a-real-secret"

    private func candidate(_ host: String = "success.enrollment.invalid", backend: APIBackend = .sleepypodCore) throws -> OwnerConnectionCandidate {
        try OwnerConnectionCandidate(address: "https://\(host)", streamAddress: "", backend: backend, token: key)
    }

    func testCandidateChecksEndpointAndStreamBeforeAnyRead() throws {
        for address in ["http://public.invalid", "https://user:password@pod.invalid", "https://pod.invalid/path", "https://pod.invalid?token=secret"] {
            XCTAssertThrowsError(try OwnerConnectionCandidate(address: address, streamAddress: "", backend: .sleepypodCore, token: key))
        }
        for stream in ["ws://pod.invalid/sensors", "wss://other.invalid/sensors", "wss://user@pod.invalid", "wss://pod.invalid?token=secret"] {
            XCTAssertThrowsError(try OwnerConnectionCandidate(address: "https://pod.invalid", streamAddress: stream, backend: .sleepypodCore, token: key))
        }
        let normalized = try OwnerConnectionCandidate(address: " HTTPS://POD.INVALID:443/ ", streamAddress: " wss://pod.invalid/sensors ", backend: .sleepypodCore, token: key)
        XCTAssertEqual(normalized.endpoint.absoluteString, "https://pod.invalid")
        XCTAssertEqual(normalized.streamAddress, "wss://pod.invalid/sensors")
        for token in ["short", key + "\nInjected: value", key + " space", key + "é"] {
            XCTAssertThrowsError(try OwnerConnectionCandidate(address: "https://pod.invalid", streamAddress: "", backend: .sleepypodCore, token: token))
        }
    }

    func testCandidateCredentialCannotAuthorizeOtherReadsOrMutations() throws {
        let checked = try candidate()
        var request = URLRequest(url: checked.endpoint.appending(path: "api/trpc/device.getStatus"))
        request.httpMethod = "GET"
        request.setValue("Bearer wrong-saved-key", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(try checked.authorizeStatusCheck(request).value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        XCTAssertEqual(try checked.authorizeStatusCheck(request).cachePolicy, .reloadIgnoringLocalCacheData)
        for method in ["POST", "PUT", "DELETE"] {
            request.httpMethod = method; XCTAssertThrowsError(try checked.authorizeStatusCheck(request))
        }
        request.httpMethod = "GET"
        for address in ["https://other.invalid/api/trpc/device.getStatus", "http://success.enrollment.invalid/api/trpc/device.getStatus",
                        "https://success.enrollment.invalid:8443/api/trpc/device.getStatus", "https://success.enrollment.invalid/api/trpc/device.setPower",
                        "https://user:password@success.enrollment.invalid/api/trpc/device.getStatus", "https://success.enrollment.invalid/api/trpc/device.getStatus#fragment"] {
            request.url = URL(string: address); XCTAssertThrowsError(try checked.authorizeStatusCheck(request))
        }
    }

    func testStatusChecksUseCandidateKeyWithoutChangingSavedConfiguration() async throws {
        let original = OwnerConnection.revision
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnrollmentStatusProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await candidate().check(session: session)
        try await candidate("legacy.enrollment.invalid", backend: .freeSleep).check(session: session)
        XCTAssertEqual(OwnerConnection.revision, original)
        for host in ["unauthorized", "forbidden", "malformed"] {
            do { try await candidate("\(host).enrollment.invalid").check(session: session); XCTFail("Expected rejected status") }
            catch {
                XCTAssertEqual(ConnectionIssue(error), host == "malformed" ? .invalidResponse : .authentication)
            }
        }
        XCTAssertEqual(OwnerConnection.revision, original)
    }

    func testFailedCheckNeverCommitsAndKeepsRecoveryMessageSpecific() async throws {
        let enrollment = OwnerConnectionEnrollment()
        var commits = 0
        let result = await enrollment.connect(try candidate(), check: { _ in throw APIError.invalidResponse(statusCode: 401) },
            isCurrent: { true }, commit: { _ in commits += 1 })
        XCTAssertFalse(result); XCTAssertEqual(commits, 0); XCTAssertFalse(enrollment.checking)
        XCTAssertTrue(enrollment.message?.contains("key") == true)
        XCTAssertTrue(enrollment.message?.contains("unchanged") == true)
        XCTAssertTrue(OwnerConnectionEnrollment.failureMessage(APIError.invalidResponse(statusCode: 403)).contains("does not have access"))
        XCTAssertTrue(OwnerConnectionEnrollment.failureMessage(URLError(.timedOut)).contains("in time"))
        XCTAssertTrue(OwnerConnectionEnrollment.failureMessage(URLError(.cannotConnectToHost)).contains("network route"))
    }

    func testSuccessfulReadCommitsExactlyTheCheckedCandidateOnce() async throws {
        let enrollment = OwnerConnectionEnrollment()
        var events: [String] = []
        let result = await enrollment.connect(try candidate(), check: { checked in
            XCTAssertTrue(enrollment.checking); events.append("checked:" + checked.endpoint.absoluteString)
        }, isCurrent: { true }, commit: { checked in events.append("saved:" + checked.endpoint.absoluteString) })
        XCTAssertTrue(result); XCTAssertEqual(events, ["checked:https://success.enrollment.invalid", "saved:https://success.enrollment.invalid"])
        XCTAssertFalse(enrollment.checking); XCTAssertEqual(enrollment.message, "Connection verified and saved.")
    }

    func testLeavingFormOrChangingAccountWithdrawsLateSuccess() async throws {
        for leavesForm in [false, true] {
            let enrollment = OwnerConnectionEnrollment()
            var current = true, committed = false
            let result = await enrollment.connect(try candidate(), check: { _ in
                if leavesForm { enrollment.invalidate() } else { current = false }
            }, isCurrent: { current }, commit: { _ in committed = true })
            XCTAssertFalse(result); XCTAssertFalse(committed); XCTAssertNil(enrollment.message)
        }
    }

    func testFailedPersistenceDoesNotClaimTheControllerIsOffline() async throws {
        let enrollment = OwnerConnectionEnrollment()
        let result = await enrollment.connect(try candidate(), check: { _ in }, isCurrent: { true },
            commit: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertFalse(result); XCTAssertFalse(enrollment.checking)
        XCTAssertTrue(enrollment.message?.contains("controller replied") == true)
        XCTAssertTrue(enrollment.message?.contains("could not be saved") == true)
    }

    func testCancellationCannotPersistAfterSuccessfulResponse() async throws {
        let enrollment = OwnerConnectionEnrollment(), checked = try candidate()
        var committed = false
        let task = Task { await enrollment.connect(checked, check: { _ in }, isCurrent: { true }, commit: { _ in committed = true }) }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result); XCTAssertFalse(committed); XCTAssertNil(enrollment.message)
    }
}

private final class EnrollmentStatusProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".enrollment.invalid") == true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-candidate-credential-not-a-real-secret")
        let status = url.host?.hasPrefix("unauthorized") == true ? 401 : url.host?.hasPrefix("forbidden") == true ? 403 : 200
        let body: String
        if url.host?.hasPrefix("legacy") == true {
            XCTAssertEqual(url.path, "/api/deviceStatus")
            body = #"{"left":{"currentTemperatureLevel":0,"secondsRemaining":0,"isOn":false,"isAlarmVibrating":false},"right":{"currentTemperatureLevel":0,"secondsRemaining":0,"isOn":false,"isAlarmVibrating":false},"waterLevel":"ok","isPriming":false,"settings":{"v":0,"gainLeft":0,"gainRight":0,"ledBrightness":0},"coverVersion":"20600","hubVersion":"I00","freeSleep":{"version":"test","branch":"synthetic"},"wifiStrength":0}"#
        } else {
            XCTAssertEqual(url.path, "/api/trpc/device.getStatus")
            body = url.host?.hasPrefix("malformed") == true ? "<html>Sign in</html>" : #"{"result":{"data":{"json":{"leftSide":{"currentLevel":0,"targetLevel":0,"heatingDuration":0},"rightSide":{"currentLevel":0,"targetLevel":0,"heatingDuration":0},"waterLevel":"ok","isPriming":false,"podVersion":"I00","sensorLabel":"20600"}}}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
