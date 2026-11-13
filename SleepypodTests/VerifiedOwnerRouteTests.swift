import XCTest
@testable import Sleepypod

@MainActor final class VerifiedOwnerRouteTests: XCTestCase {
    private let key = "synthetic-route-credential-never-a-real-secret"
    private let revision = "synthetic-owner-revision"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidates() throws -> (home: OwnerConnectionCandidate, away: OwnerConnectionCandidate) {
        (try .init(address: "http://10.0.0.123:3000", streamAddress: "", backend: .sleepypodCore, token: key),
         try .init(address: "https://away.routes.invalid", streamAddress: "wss://away.routes.invalid/sensors", backend: .sleepypodCore, token: key + "-away"))
    }

    private func profile(_ candidates: (home: OwnerConnectionCandidate, away: OwnerConnectionCandidate)) throws -> VerifiedOwnerRoutes {
        try .init(installationID: UUID(), credentialRevision: revision, home: candidates.home, away: candidates.away, now: now)
    }

    func testBothExplicitOriginsMustReturnTheSameIdentityBeforeEnrollment() async throws {
        let candidates = try candidates(), identity = UUID()
        var reads: [String] = []
        let verified = try await OwnerRouteVerification.verify(home: candidates.home, away: candidates.away,
            currentAddress: candidates.home.endpoint.absoluteString, credentialRevision: revision, now: now,
            isCurrent: { true }, readIdentity: { candidate in reads.append(candidate.endpoint.absoluteString); return identity })
        XCTAssertEqual(reads, [candidates.home.endpoint.absoluteString, candidates.away.endpoint.absoluteString])
        XCTAssertEqual(verified.installationID, identity)
        XCTAssertTrue(verified.enabled)
        let data = try JSONEncoder().encode(verified)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(key))
        XCTAssertEqual(try JSONDecoder().decode(VerifiedOwnerRoutes.self, from: data), verified)
    }

    func testEnrollmentRejectsDifferentControllerAndAccountChangedBetweenReads() async throws {
        let candidates = try candidates()
        for changesAccount in [false, true] {
            var current = true, reads = 0
            do {
                _ = try await OwnerRouteVerification.verify(home: candidates.home, away: candidates.away,
                    currentAddress: candidates.home.endpoint.absoluteString, credentialRevision: revision, now: now,
                    isCurrent: { current }, readIdentity: { _ in
                        reads += 1
                        if changesAccount { current = false }
                        return UUID()
                    })
                XCTFail("Unverified alternatives must not enroll")
            } catch let error as ControllerIdentityFailure {
                if changesAccount { XCTAssertEqual(reads, 1); XCTAssertTrue(error.localizedDescription.contains("account changed")) }
                else { XCTAssertEqual(reads, 2); XCTAssertTrue(error.localizedDescription.contains("different controller")) }
            }
        }
    }

    func testEnrollmentIdentifiesTheFailedConnectionWithoutTryingPastItsFailure() async throws {
        let candidates = try candidates(), identity = UUID()
        for failedConnection in [OwnerRouteCheckFailure.Connection.home, .away] {
            for failure in [APIError.invalidResponse(statusCode: 401), .networkError(URLError(.timedOut)),
                            .networkError(URLError(.serverCertificateUntrusted))] {
                var reads: [String] = []
                do {
                    _ = try await OwnerRouteVerification.verify(home: candidates.home, away: candidates.away,
                        currentAddress: candidates.home.endpoint.absoluteString, credentialRevision: revision, now: now,
                        isCurrent: { true }, readIdentity: { candidate in
                            reads.append(candidate.endpoint.absoluteString)
                            if (candidate.endpoint == candidates.home.endpoint) == (failedConnection == .home) { throw failure }
                            return identity
                        })
                    XCTFail("Failed verification must not create a profile")
                } catch let scoped as OwnerRouteCheckFailure {
                    XCTAssertEqual(scoped.connection, failedConnection)
                    XCTAssertTrue(scoped.localizedDescription.hasPrefix(failedConnection.rawValue + " connection"))
                    XCTAssertTrue(scoped.localizedDescription.contains("saved setup is unchanged"))
                    XCTAssertEqual(reads, failedConnection == .home
                        ? [candidates.home.endpoint.absoluteString] : [candidates.home.endpoint.absoluteString, candidates.away.endpoint.absoluteString])
                }
            }
        }
    }

    func testScopedRecoveryDoesNotEchoServerErrorDetailsOrMislabelAnAwayNetwork() {
        let privateFailure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-server-response"])
        XCTAssertFalse(OwnerRouteCheckFailure(connection: .home, error: privateFailure).localizedDescription.contains("private-server-response"))
        let awayFailure = OwnerRouteCheckFailure(connection: .away, error: URLError(.cannotConnectToHost)).localizedDescription
        XCTAssertTrue(awayFailure.contains("HTTPS")); XCTAssertTrue(awayFailure.contains("gateway"))
        XCTAssertFalse(awayFailure.contains("home Wi-Fi"))
    }

    func testEnrollmentCancellationRemainsCancellation() async throws {
        let candidates = try candidates()
        do {
            _ = try await OwnerRouteVerification.verify(home: candidates.home, away: candidates.away,
                currentAddress: candidates.home.endpoint.absoluteString, credentialRevision: revision, now: now,
                isCurrent: { true }, readIdentity: { _ in throw CancellationError() })
            XCTFail("Cancelled enrollment must stop")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testShapeAndCredentialChangesFailBeforeSendingCredentials() async throws {
        let candidates = try candidates(), profile = try profile(candidates)
        for address in ["https://other.routes.invalid", ""] {
            XCTAssertThrowsError(try profile.candidates(currentAddress: address, revision: revision, key: { _ in self.key }))
        }
        XCTAssertThrowsError(try profile.candidates(currentAddress: profile.home.address, revision: "replacement", key: { _ in self.key }))
        XCTAssertThrowsError(try profile.candidates(currentAddress: profile.home.address, revision: revision, key: { _ in self.key }))
        let restored = try profile.candidates(currentAddress: profile.away.address, revision: revision,
            key: { $0 == profile.home.address ? self.key : self.key + "-away" })
        XCTAssertEqual(restored.away.endpoint.absoluteString, profile.away.address)
        var reads = 0
        do {
            _ = try await OwnerRouteVerification.verify(home: candidates.home, away: candidates.home,
                currentAddress: profile.home.address, credentialRevision: revision, now: now,
                isCurrent: { true }, readIdentity: { _ in reads += 1; return UUID() })
            XCTFail("Identical origins must fail")
        } catch { XCTAssertEqual(reads, 0) }
        XCTAssertThrowsError(try VerifiedOwnerRoutes(installationID: UUID(), credentialRevision: "", home: candidates.home, away: candidates.away, now: now))
        XCTAssertThrowsError(try VerifiedOwnerRoutes(installationID: UUID(), credentialRevision: revision, home: candidates.home, away: candidates.away, now: .init(timeIntervalSince1970: .infinity)))
    }

    func testHealthyCurrentRouteIsReadWithoutReconfiguration() async throws {
        let candidates = try candidates(), profile = try profile(candidates), resolver = OwnerRouteResolver()
        var reads: [String] = [], activations = 0
        let result = await resolver.resolve(profile: profile, currentAddress: profile.away.address, candidates: candidates,
            readIdentity: { candidate in reads.append(candidate.endpoint.absoluteString); return profile.installationID },
            isCurrent: { true }, activate: { _ in activations += 1 })
        XCTAssertTrue(result); XCTAssertEqual(reads, [profile.away.address]); XCTAssertEqual(activations, 0)
        XCTAssertEqual(resolver.lastVerifiedAddress, profile.away.address)
    }

    func testNetworkFailureTriesOnlyVerifiedAlternativeWithItsOwnKey() async throws {
        let candidates = try candidates(), profile = try profile(candidates), resolver = OwnerRouteResolver()
        var reads: [String] = [], activations: [String] = []
        let result = await resolver.resolve(profile: profile, currentAddress: profile.home.address, candidates: candidates,
            readIdentity: { candidate in
                reads.append(candidate.endpoint.absoluteString)
                if candidate.endpoint.absoluteString == profile.home.address { throw URLError(.cannotConnectToHost) }
                XCTAssertEqual(candidate.token, self.key + "-away")
                return profile.installationID
            }, isCurrent: { true }, activate: { activations.append($0.endpoint.absoluteString) })
        XCTAssertTrue(result); XCTAssertEqual(reads, [profile.home.address, profile.away.address])
        XCTAssertEqual(activations, [profile.away.address]); XCTAssertEqual(resolver.message, "Away connection verified.")
    }

    func testAuthenticationCertificateMalformedAndUnknownFailuresNeverFallBack() async throws {
        let candidates = try candidates(), profile = try profile(candidates)
        let failures: [Error] = [APIError.invalidResponse(statusCode: 401), APIError.invalidResponse(statusCode: 403),
            APIError.invalidResponse(statusCode: 503), URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed),
            URLError(.cancelled), ControllerIdentityFailure.invalidReply, CocoaError(.fileReadCorruptFile)]
        for failure in failures {
            let resolver = OwnerRouteResolver()
            var reads = 0, activations = 0
            let result = await resolver.resolve(profile: profile, currentAddress: profile.home.address, candidates: candidates,
                readIdentity: { _ in reads += 1; throw failure }, isCurrent: { true }, activate: { _ in activations += 1 })
            XCTAssertFalse(result); XCTAssertEqual(reads, 1); XCTAssertEqual(activations, 0)
            XCTAssertNil(resolver.lastVerifiedAddress)
        }
    }

    func testWrongIdentityLateReplyAndDisabledProfileCannotActivate() async throws {
        let candidates = try candidates(), saved = try profile(candidates)
        for scenario in 0..<4 {
            var profile = saved, current = true, reads = 0, activations = 0
            if scenario == 3 { profile.enabled = false }
            let resolver = OwnerRouteResolver()
            let result = await resolver.resolve(profile: profile, currentAddress: profile.home.address, candidates: candidates,
                readIdentity: { _ in
                    reads += 1
                    if scenario == 0 { return UUID() }
                    if scenario == 1 { current = false }
                    if scenario == 2 { resolver.invalidate() }
                    return saved.installationID
                }, isCurrent: { current }, activate: { _ in activations += 1 })
            XCTAssertFalse(result); XCTAssertEqual(activations, 0); XCTAssertNil(resolver.lastVerifiedAddress)
            XCTAssertEqual(reads, scenario == 3 ? 0 : 1)
        }
    }

    func testLocalActivationFailureCannotTriggerAnotherRouteOrClaimSuccess() async throws {
        let candidates = try candidates(), profile = try profile(candidates), resolver = OwnerRouteResolver()
        var activations = 0
        let result = await resolver.resolve(profile: profile, currentAddress: profile.home.address, candidates: candidates,
            readIdentity: { candidate in
                if candidate.endpoint.absoluteString == profile.home.address { throw URLError(.timedOut) }
                return profile.installationID
            }, isCurrent: { true }, activate: { _ in activations += 1; throw CocoaError(.fileWriteNoPermission) })
        XCTAssertFalse(result); XCTAssertEqual(activations, 1); XCTAssertNil(resolver.lastVerifiedAddress)
        XCTAssertTrue(resolver.message?.contains("could not switch") == true)
    }

    func testModifiedRouteMetadataAndKeysCannotAuthorizeReads() async throws {
        let candidates = try candidates(), profile = try profile(candidates), resolver = OwnerRouteResolver()
        let changed = try OwnerConnectionCandidate(address: profile.away.address, streamAddress: "", backend: .sleepypodCore, token: key)
        var reads = 0
        let result = await resolver.resolve(profile: profile, currentAddress: profile.home.address,
            candidates: (home: candidates.home, away: changed), readIdentity: { _ in reads += 1; return profile.installationID },
            isCurrent: { true }, activate: { _ in XCTFail("Must not activate altered metadata") })
        XCTAssertFalse(result); XCTAssertEqual(reads, 0)
    }

    func testFallbackClassificationPreservesNestedNetworkAndRejectsUnknownError() {
        XCTAssertTrue(OwnerRouteResolver.permitsFallback(after: APIError.networkError(URLError(.timedOut))))
        XCTAssertTrue(OwnerRouteResolver.permitsFallback(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(OwnerRouteResolver.permitsFallback(after: APIError.invalidResponse(statusCode: 302)))
    }
}
