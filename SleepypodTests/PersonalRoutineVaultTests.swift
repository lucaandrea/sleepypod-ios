import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class PersonalRoutineVaultTests: XCTestCase {
    private func setup(markers: [PersonalControlTombstone] = [], controls: PersonalTestServer? = nil) throws -> (HouseholdWorkspace, PublicationTestVault, PersonalRoutineTestServer) {
        let review = try PersonalRoutineFixtures.review(), session = try PersonalRoutineFixtures.session()
        var record = HouseholdConnectionRecord(id: UUID(), endpoint: URL(string: "https://publication-parent.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
        record.draftPreferences = .blank; record.draftPreferencesRevision = 1
        let other = HouseholdConnectionRecord(id: UUID(), endpoint: record.endpoint, deviceSecret: String(repeating: "B", count: 43))
        let vault = PublicationTestVault(state: .init(connections: [record, other], selected: record.id, controlTombstones: markers))
        let defaults = UserDefaults(suiteName: "publication-parent-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let server = PersonalRoutineTestServer(review: review, session: session)
        let parent = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, personalClient: { connection in
            if let controls { return controls }; return PersonalBedHTTPClient(connection: connection)
        }, routineClient: { _ in server },
            capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in XCTFail("No owner fallback"); return "" }, secret: { String(repeating: "C", count: 43) })
        return (parent, vault, server)
    }
    private func publish(_ parent: HouseholdWorkspace) async throws -> PersonalRoutineWorkspace {
        await parent.refresh(); let model = try XCTUnwrap(parent.publication)
        await model.refresh(); model.confirmReplaceLiveWeek = true; model.acknowledgeCurrentTargetEffect = true
        await model.publish(); return model
    }
    func testParentWriterKeepsOtherAccountsDraftsAndPublicationsAcrossRefresh() async throws {
        let (parent, vault, _) = try setup()
        let model = try await publish(parent)
        XCTAssertEqual(vault.state.connections.first?.personalPublications?.first?.receipt?.scheduler, "refreshed")
        XCTAssertEqual(vault.state.connections.first?.draftPreferences, .blank)
        XCTAssertEqual(vault.state.connections.last?.deviceSecret, String(repeating: "B", count: 43))
        await parent.refresh(); XCTAssertTrue(parent.publication === model)
        parent.signOut(); XCTAssertNil(parent.publication); XCTAssertTrue(model.attempts.isEmpty)
        XCTAssertEqual(vault.state.connections.first?.personalPublications?.count, 1)
    }
    func testRevocationErasesPrivateWeekAndRepairOnlyLooksUpOriginalOwnReceipt() async throws {
        let (parent, vault, server) = try setup(); await server.configure(postFailure: .uncertain)
        let model = try await publish(parent)
        let original = try XCTUnwrap(vault.state.connections.first?.personalPublications?.first)
        await server.configure(sessionFailure: .authentication); await model.refresh()
        XCTAssertNil(parent.publication); XCTAssertNil(vault.state.selected)
        let marker = try XCTUnwrap(vault.state.publicationTombstones?.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(marker)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["identity", "requestId", "expiresAt", "unresolvedState"])
        let retained = String(decoding: try JSONEncoder().encode(vault.state), as: UTF8.self)
        XCTAssertFalse(retained.contains(String(repeating: "A", count: 43))); XCTAssertFalse(retained.contains("Synthetic example"))
        XCTAssertFalse(retained.contains("reviewRevision")); XCTAssertTrue(parent.publicationRecoveries.isEmpty)
        await parent.reconcilePublicationRecovery(marker.id)
        let before = await server.lookups; XCTAssertTrue(before.isEmpty)
        await server.configure()
        await parent.start(address: "https://publication-parent.invalid", name: "Fixture Sleeper", deviceName: "Repaired phone", invitation: String(repeating: "D", count: 43))
        XCTAssertEqual(parent.publicationRecoveries, [marker])
        let restored = try XCTUnwrap(parent.publication); await restored.refresh()
        restored.confirmReplaceLiveWeek = true; restored.acknowledgeCurrentTargetEffect = true
        XCTAssertFalse(restored.canPublish)
        await parent.reconcilePublicationRecovery(marker.id)
        let posts = await server.posts, lookups = await server.lookups
        XCTAssertEqual(posts.count, 1); XCTAssertEqual(lookups, [original.id]); XCTAssertTrue(parent.publicationRecoveries.isEmpty)
        XCTAssertTrue(parent.notice?.contains("Week saved") == true)
    }
    func testSharedRecoveryCapacityAndVaultFailureBlockPublicationBeforePost() async throws {
        let identity = try PersonalRoutineFixtures.session().identity
        let markers = (0..<64).map { _ in PersonalControlTombstone(identity: identity, requestId: UUID(), expiresAt: 1_793_314_830_000, unresolvedState: "executing") }
        let (parent, vault, server) = try setup(markers: markers)
        _ = try await publish(parent)
        var posts = await server.posts; XCTAssertTrue(posts.isEmpty); XCTAssertEqual(vault.state.controlTombstones, markers)
        let (second, failing, secondServer) = try setup()
        await second.refresh(); let model = try XCTUnwrap(second.publication); await model.refresh()
        model.confirmReplaceLiveWeek = true; model.acknowledgeCurrentTargetEffect = true; failing.reject = true
        await model.publish(); posts = await secondServer.posts; XCTAssertTrue(posts.isEmpty)
        XCTAssertNil(failing.state.connections.first?.personalPublications)
    }
    func testLateRecoveryAfterSignOutIsHiddenAndEraseIncludesPublicationReferences() async throws {
        let (parent, vault, server) = try setup(); await server.configure(postFailure: .uncertain)
        let model = try await publish(parent)
        await server.configure(sessionFailure: .authentication); await model.refresh(); await server.configure()
        await parent.start(address: "https://publication-parent.invalid", name: "Fixture Sleeper", deviceName: "Repaired phone", invitation: String(repeating: "D", count: 43))
        let marker = try XCTUnwrap(parent.publicationRecoveries.first)
        await server.hold("receipt")
        let operation = Task { await parent.reconcilePublicationRecovery(marker.id) }
        await server.waitHeld(); parent.signOut(); await server.release(); await operation.value
        XCTAssertTrue(parent.publicationRecoveries.isEmpty); XCTAssertNil(parent.notice)
        XCTAssertEqual(vault.state.publicationTombstones, [marker])
        parent.erasePersonalLocalData(); XCTAssertTrue(vault.state.connections.isEmpty); XCTAssertNil(vault.state.publicationTombstones)
    }
    func testStopFromTemperatureWorkspacePreemptsPublicationPreflight() async throws {
        let controls = try PersonalTestServer(bed: PersonalControlFixtures.bed(), session: PersonalRoutineFixtures.session())
        let (parent, vault, server) = try setup(controls: controls)
        await parent.refresh(); let publication = try XCTUnwrap(parent.publication), temperature = try XCTUnwrap(parent.temperature)
        await publication.refresh(); publication.confirmReplaceLiveWeek = true; publication.acknowledgeCurrentTargetEffect = true
        await server.hold("review")
        let operation = Task { await publication.publish() }
        await server.waitHeld(); await temperature.refresh(); await temperature.submit(.init(kind: "power", powered: false))
        await server.release(); await operation.value
        let publications = await server.posts, stops = await controls.posts
        XCTAssertTrue(publications.isEmpty); XCTAssertEqual(stops.count, 1)
        XCTAssertNil(vault.state.connections.first?.personalPublications)
        XCTAssertTrue(publication.error?.contains("cancelled by Stop") == true)
    }
    func testExplicitSavedDraftReloadClearsRetainedDraftWithoutDroppingOtherPrivateState() async throws {
        let (_, vault, _) = try setup()
        vault.state.connections[0].draftRoutines = []
        vault.state.connections[0].draftRoutinesRevision = 2
        // Load through a fresh parent so the retained draft matches what Keychain returned.
        let defaults = UserDefaults(suiteName: "publication-reload-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let server = try PersonalRoutineTestServer(review: PersonalRoutineFixtures.review(), session: PersonalRoutineFixtures.session())
        let restored = HouseholdWorkspace(vault: vault, defaults: defaults, client: { _ in server }, routineClient: { _ in server },
            capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        await restored.refresh(); XCTAssertTrue(restored.draftRoutines.isEmpty)
        XCTAssertTrue(restored.discardRetainedRoutineDraft())
        XCTAssertEqual(restored.draftRoutines.count, 1); XCTAssertNil(vault.state.connections[0].draftRoutines)
        XCTAssertEqual(vault.state.connections[0].draftPreferences, .blank); XCTAssertEqual(vault.state.connections.count, 2)
        vault.reject = true; XCTAssertFalse(restored.discardRetainedRoutineDraft())
    }
    func testUnknownEffectsBlockOrdinaryChangesAcrossBothWorkspacesButKeepStops() async throws {
        let controls = try PersonalTestServer(bed: PersonalControlFixtures.currentBed(), session: PersonalRoutineFixtures.session())
        let (parent, vault, server) = try setup(controls: controls)
        await parent.refresh(); let temperature = try XCTUnwrap(parent.temperature); await temperature.refresh()
        XCTAssertTrue(temperature.canAdjust)
        await server.configure(postFailure: .uncertain); let publication = try await publish(parent)
        XCTAssertFalse(temperature.canAdjust); XCTAssertTrue(temperature.canStopPower); XCTAssertTrue(temperature.canStopVibration)
        await publication.reconcile(try XCTUnwrap(vault.state.connections.first?.personalPublications?.first?.id))
        XCTAssertTrue(temperature.canAdjust)
        await controls.configure(postFailure: .uncertain); await temperature.submit(.init(kind: "temperature", temperatureF: 70, holdMinutes: 30))
        await publication.refresh(); publication.confirmReplaceLiveWeek = true; publication.acknowledgeCurrentTargetEffect = true
        XCTAssertFalse(publication.canPublish); XCTAssertTrue(temperature.canStopPower)
    }
    func testPublicationMarkerNeverMatchesAnotherAccountWithSameSleeperNameOrSide() throws {
        let session = try PersonalRoutineFixtures.session()
        let marker = PersonalRoutineTombstone(identity: session.identity, requestId: UUID(), expiresAt: 1_793_314_830_000, unresolvedState: "awaiting")
        let other = try PersonalRoutineFixtures.changed(session) { $0["accountId"] = UUID().uuidString }
        XCTAssertTrue(marker.matches(session)); XCTAssertFalse(marker.matches(other))
    }
}

@MainActor private final class PublicationTestVault: HouseholdVault {
    var state: HouseholdVaultState
    var reject = false
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { if reject { throw HouseholdFailure.storage }; self.state = state }
}
