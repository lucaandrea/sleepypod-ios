import XCTest
@testable import Sleepypod

@MainActor final class OwnerRouteSessionTests: XCTestCase {
    func testEnrollmentRequiresCurrentCredentialAndPersistsOnlyAfterBothIdentities() async throws {
        let storage = RouteSessionFixture(), session = storage.session()
        let candidates = try storage.candidates()
        let result = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertTrue(result)
        XCTAssertEqual(storage.events, ["identity-home", "identity-away", "key-away", "profile"])
        XCTAssertEqual(storage.profile?.originalRevision, storage.revision)
        XCTAssertEqual(storage.keys[candidates.away.endpoint.absoluteString], candidates.away.token)
        XCTAssertEqual(storage.revision[1], candidates.home.endpoint.absoluteString)
        XCTAssertTrue(session.profile?.routes.enabled == true)
        XCTAssertNotNil(session.checkedAt)
    }

    func testOldConnectionReceivesRevisionWithoutOrphaningExistingDataIdentity() async throws {
        let storage = RouteSessionFixture(); storage.revision[3] = ""
        let original = storage.revision, session = storage.session(), candidates = try storage.candidates()
        let result = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertTrue(result); XCTAssertFalse(storage.revision[3].isEmpty)
        let profile = try XCTUnwrap(storage.profile)
        try profile.validateContext(storage.revision)
        XCTAssertEqual(profile.originalRevision, original)
        XCTAssertEqual(OwnerDataIdentity.owner(profile.originalRevision).phoneBackupScope, OwnerDataIdentity.owner(original).phoneBackupScope)
        XCTAssertEqual(storage.events.last, "establish-revision")
    }

    func testCurrentKeyReplacementCannotSendEitherOriginARequest() async throws {
        let storage = RouteSessionFixture(), session = storage.session(), candidates = try storage.candidates()
        storage.keys[candidates.home.endpoint.absoluteString] = "a-different-key-from-the-current-connection"
        let result = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertFalse(result); XCTAssertTrue(storage.events.isEmpty); XCTAssertNil(storage.profile)
    }

    func testRejectedIdentityAndAccountSwitchDoNotWriteKeysOrProfile() async throws {
        for scenario in ["different", "account", "authentication", "cancel"] {
            let storage = RouteSessionFixture(); storage.scenario = scenario
            let session = storage.session(), candidates = try storage.candidates()
            let result = await session.enroll(home: candidates.home, away: candidates.away)
            XCTAssertFalse(result); XCTAssertNil(storage.profile)
            XCTAssertFalse(storage.events.contains("key-away"))
        }
    }

    func testProfileWriteFailureRestoresAlternateKeyAndRetainsCurrentConnection() async throws {
        let storage = RouteSessionFixture(); storage.saveFailure = true
        let original = storage.revision, session = storage.session(), candidates = try storage.candidates()
        storage.keys[candidates.away.endpoint.absoluteString] = "previous-unused-alternate-key"
        let result = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertFalse(result); XCTAssertNil(storage.profile); XCTAssertEqual(storage.revision, original)
        XCTAssertEqual(storage.keys[candidates.away.endpoint.absoluteString], "previous-unused-alternate-key")
        XCTAssertEqual(storage.events.suffix(3), ["key-away", "profile", "key-away"])
    }

    func testUnreadableExistingProfileCannotBeOverwrittenDuringEnrollment() async throws {
        let storage = RouteSessionFixture(); storage.loadFailure = true
        let session = storage.session(), candidates = try storage.candidates()
        let result = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertFalse(result); XCTAssertTrue(storage.events.isEmpty)
    }

    func testReadOnlyRecoverySelectsOnlyVerifiedAlternativeAndRetainsLogicalOwner() async throws {
        let storage = RouteSessionFixture(), session = storage.session(), candidates = try storage.candidates()
        let enrolled = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertTrue(enrolled)
        let original = storage.revision; storage.events = []; storage.scenario = "network"
        var activations = 0
        await session.resolve { candidate in
            activations += 1; storage.revision[1] = candidate.endpoint.absoluteString; storage.revision[2] = candidate.endpoint.host ?? ""
        }
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(storage.events, ["identity-home", "identity-away"])
        XCTAssertEqual(storage.profile?.originalRevision, original)
        XCTAssertNotNil(session.checkedAt)
        storage.events = []
        await session.resolve { _ in XCTFail("Healthy away connection should be retained") }
        XCTAssertEqual(storage.events, ["identity-away"])
    }

    func testDisabledProfilesAndCredentialChangeCannotActivate() async throws {
        let storage = RouteSessionFixture(), session = storage.session(), candidates = try storage.candidates()
        _ = await session.enroll(home: candidates.home, away: candidates.away)
        session.setEnabled(false); storage.events = []
        await session.resolve { _ in XCTFail("Disabled profile must not activate") }
        XCTAssertTrue(storage.events.isEmpty)
        XCTAssertFalse(storage.profile!.routes.enabled)
        session.setEnabled(true); storage.events = []; storage.scenario = "network"
        storage.afterRead = { storage.profile?.routes.enabled = false }
        await session.resolve { _ in XCTFail("Changed metadata cannot authorize activation") }
        XCTAssertNil(session.checkedAt)
    }

    func testForegroundInvalidationAndKnownAccountChangeDiscardLateResults() async throws {
        for scenario in ["invalidate", "account"] {
            let storage = RouteSessionFixture(), session = storage.session(), candidates = try storage.candidates()
            _ = await session.enroll(home: candidates.home, away: candidates.away)
            if scenario == "invalidate" { storage.afterRead = { session.invalidate() } }
            else { storage.scenario = "account" }
            await session.resolve { _ in XCTFail("Late result cannot activate") }
            XCTAssertNil(session.checkedAt); XCTAssertNil(session.profile)
        }
    }

    func testEditingRetainsEnrollmentFeedbackAndRecoveryResumesAfterDismissal() async throws {
        let storage = RouteSessionFixture(), session = storage.session(), candidates = try storage.candidates()
        session.beginEditing()
        let enrolled = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertTrue(enrolled)
        let result = session.message, profile = session.profile
        storage.events = []; storage.scenario = "network"
        await session.resolve { _ in XCTFail("Recovery cannot replace a connection while its form is open") }
        XCTAssertTrue(storage.events.isEmpty)
        XCTAssertEqual(session.profile, profile); XCTAssertEqual(session.message, result)
        XCTAssertFalse(session.busy)
        session.endEditing()
        var activated = false
        await session.resolve { candidate in
            activated = true; storage.revision[1] = candidate.endpoint.absoluteString; storage.revision[2] = candidate.endpoint.host ?? ""
        }
        XCTAssertTrue(activated); XCTAssertFalse(session.editing)
        XCTAssertEqual(storage.events, ["identity-home", "identity-away"])
    }

    func testOpeningFormCancelsAnInFlightRecoveryBeforeItCanActivate() async throws {
        let storage = RouteSessionFixture(), session = storage.session(), candidates = try storage.candidates()
        _ = await session.enroll(home: candidates.home, away: candidates.away)
        storage.scenario = "network"
        storage.afterRead = { session.beginEditing() }
        await session.resolve { _ in XCTFail("A pre-edit response cannot replace the form's connection") }
        XCTAssertTrue(session.editing); XCTAssertFalse(session.busy)
        XCTAssertNil(session.checkedAt)
        XCTAssertEqual(storage.revision[1], candidates.home.endpoint.absoluteString)
    }

    func testBackgroundInvalidationPreventsLateEnrollmentWrites() async throws {
        let storage = RouteSessionFixture(), session = storage.session(), candidates = try storage.candidates()
        session.beginEditing()
        storage.afterRead = { session.invalidate() }
        let enrolled = await session.enroll(home: candidates.home, away: candidates.away)
        XCTAssertFalse(enrolled); XCTAssertNil(storage.profile)
        XCTAssertEqual(storage.events, ["identity-home"])
        XCTAssertFalse(session.busy)
    }
}

@MainActor private final class RouteSessionFixture {
    var revision = ["sleepypod-core", "http://10.0.0.123:3000", "10.0.0.123", "owner-revision", "owner-boundary"]
    var keys = ["http://10.0.0.123:3000": "synthetic-session-home-credential-never-real"]
    var profile: EnrolledOwnerRoutes?
    var events: [String] = []
    var scenario = "success"
    var saveFailure = false
    var loadFailure = false
    var afterRead: (() -> Void)?
    let installation = UUID()

    func candidates() throws -> (home: OwnerConnectionCandidate, away: OwnerConnectionCandidate) {
        (try .init(address: "http://10.0.0.123:3000", streamAddress: "", backend: .sleepypodCore, token: "synthetic-session-home-credential-never-real"),
         try .init(address: "https://away.session.invalid", streamAddress: "", backend: .sleepypodCore, token: "synthetic-session-away-credential-never-real"))
    }

    func session() -> OwnerRouteSession {
        .init(revision: { self.revision }, allowed: { true }, key: { self.keys[$0] ?? "" },
            saveKey: { self.events.append("key-away"); self.keys[$0] = $1 },
            load: { revision in
                if self.loadFailure { throw CocoaError(.fileReadNoPermission) }
                if let profile = self.profile {
                    try profile.validateContext(revision)
                    _ = try profile.routes.candidates(currentAddress: revision[1], revision: revision[3], key: { self.keys[$0] ?? "" })
                }
                return self.profile
            }, save: { profile, revision in
                self.events.append("profile")
                if self.saveFailure { throw CocoaError(.fileWriteNoPermission) }
                try profile.validateContext(revision); self.profile = profile
            }, establishRevision: { self.events.append("establish-revision"); self.revision[3] = $0 },
            identity: { candidate in
                let home = candidate.endpoint.scheme == "http"
                self.events.append(home ? "identity-home" : "identity-away")
                self.afterRead?()
                if self.scenario == "authentication" { throw APIError.invalidResponse(statusCode: 401) }
                if self.scenario == "cancel" { throw CancellationError() }
                if self.scenario == "network", home { throw URLError(.timedOut) }
                if self.scenario == "account" { self.revision[3] = "new-owner" }
                return self.scenario == "different" ? UUID() : self.installation
            })
    }
}
