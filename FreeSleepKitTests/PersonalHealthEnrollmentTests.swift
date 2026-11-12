import CryptoKit
import Foundation
import Testing
@testable import FreeSleepKit

@MainActor struct PersonalHealthEnrollmentTests {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private func personal(_ body: @MainActor () async throws -> Void) async rethrows {
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            try await PersonalWorkspaceBoundary.$suppliedActive.withValue(true, operation: body)
        }
    }
    private func identity() -> PersonalHealthIdentity {
        .init(podID: UUID(), householdID: UUID(), accountID: UUID(), sleeperID: UUID())
    }
    private func access(identity: PersonalHealthIdentity? = nil, connection: UUID = UUID(), credential: String = String(repeating: "a", count: 64),
                        session: Int = 1, household: Int = 1, assignment: Int = 1) throws -> PersonalHealthAccess {
        try .init(identity: identity ?? self.identity(), connectionID: connection, credentialRevision: credential,
                  sessionRevision: session, householdRevision: household, assignmentRevision: assignment)
    }
    private func history(sources: Int = 2) -> HealthHistory {
        .init(importedAt: instant, timeZone: "America/Los_Angeles", sources: (0..<sources).map { index in
            .init(id: "source-\(index)", name: "Source \(index)", nights: [
                .init(id: "night", start: instant.addingTimeInterval(-30_000), end: instant.addingTimeInterval(-1000),
                      asleepMinutes: 420, deepMinutes: 70, remMinutes: 80)
            ])
        }, ignoredSamples: 0, watchNights: [])
    }
    private func fixture() -> (URL, PersonalHealthStore, PrivateSnapshotStore) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        let snapshots = PrivateSnapshotStore(directory: directory, namespace: "personal-health-test", encryptionKey: { key })
        return (directory, .init(snapshots: snapshots), snapshots)
    }
    private func model(_ state: PersonalHealthTestState, store: PersonalHealthStore,
                       authorize: @escaping @MainActor () async throws -> Void = {},
                       read: @escaping @MainActor () async throws -> HealthHistory) -> PersonalHealthWorkspace {
        .init(access: state.original, displayName: "Example sleeper", store: store, currentAccess: { state.current },
              importPermitted: { state.connected }, protectedDataAvailable: { state.unlocked },
              authorizeHistory: authorize, readHistory: read, now: { state.now })
    }

    @Test func reportEvidencePinsOneSourceAndDetectsSourceDeletionOrReplacement() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant)
            let workspace = model(state, store: store, read: { history() })
            workspace.restore()
            #expect(workspace.reportEvidence(at: instant) == nil)
            workspace.enroll(confirmedOwnHealth: true); await workspace.importHistory()
            let first = try #require(workspace.reportEvidence(at: instant))
            #expect(first.identity == state.original.identity); #expect(first.sourceID == "source-0")
            #expect(workspace.reportEvidenceIsCurrent(first)); #expect(first.comparison?.sourceName == "Source 0")
            workspace.selectSource("source-1")
            #expect(!workspace.reportEvidenceIsCurrent(first))
            let second = try #require(workspace.reportEvidence(at: instant))
            #expect(second.sourceID == "source-1"); #expect(second.healthRevision != first.healthRevision)
            #expect(workspace.reportEvidence(at: instant.addingTimeInterval(-1)) == nil)
            workspace.forget()
            #expect(!workspace.reportEvidenceIsCurrent(second)); #expect(workspace.reportEvidence(at: instant) == nil)
        }
    }

    @Test func noHealthReadOrPermissionRequestBeforeExplicitPersonConfirmation() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant)
            var reads = 0, permissions = 0
            let workspace = model(state, store: store, authorize: { permissions += 1 }, read: { reads += 1; return history() })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: false)
            await workspace.importHistory(); await workspace.refreshOnActivation()
            #expect(workspace.status == .consentRequired); #expect(try store.read() == nil)
            #expect(reads == 0); #expect(permissions == 0)
            workspace.enroll(confirmedOwnHealth: true)
            #expect(workspace.status == .ready); #expect(workspace.history == nil)
            await workspace.importHistory()
            #expect(reads == 1); #expect(permissions == 1); #expect(workspace.sources.count == 2)
        }
    }

    @Test func enrollmentNeverReadsOrTransfersExistingOwnerArchive() async throws {
        try await personal {
            let (directory, store, snapshots) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            try snapshots.write(PersonalIntelligenceArchive(history: history()), scope: "device-owner")
            let state = PersonalHealthTestState(try access(), now: instant)
            let workspace = model(state, store: store, read: { history(sources: 0) })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true)
            #expect(workspace.sources.isEmpty); #expect(workspace.history == nil)
            #expect(try snapshots.read(PersonalIntelligenceArchive.self, scope: "device-owner")?.history.sources.count == 2)
        }
    }

    @Test func anotherAccountCannotReadOverwriteOrDeleteTheDeviceBinding() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let owner = PersonalHealthTestState(try access(), now: instant)
            let first = model(owner, store: store, read: { history() })
            first.restore(); first.enroll(confirmedOwnHealth: true); await first.importHistory()
            let original = try store.read()
            let partner = PersonalHealthTestState(try access(), now: instant)
            var reads = 0
            let other = model(partner, store: store, read: { reads += 1; return history() })
            other.restore(); other.enroll(confirmedOwnHealth: true); other.forget(); await other.importHistory()
            #expect(other.status == .anotherAccount); #expect(other.sources.isEmpty); #expect(other.history == nil)
            #expect(reads == 0); #expect(try store.read() == original)
        }
    }

    @Test func assignmentAndCredentialChangesKeepOwnershipButInvalidateOldAccess() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let firstAccess = try access()
            let state = PersonalHealthTestState(firstAccess, now: instant)
            let old = model(state, store: store, read: { history() })
            old.restore(); old.enroll(confirmedOwnHealth: true); await old.importHistory()
            let changed = try access(identity: firstAccess.identity, credential: String(repeating: "b", count: 64), session: 2, household: 3, assignment: 4)
            state.current = changed
            #expect(old.status == .invalidated); #expect(old.history == nil); #expect(old.message == nil)
            let refreshed = model(PersonalHealthTestState(changed, now: instant), store: store, read: { history() })
            refreshed.restore()
            #expect(refreshed.status == .ready); #expect(refreshed.sources.count == 2)
            #expect(try store.read()?.identity == firstAccess.identity)
        }
    }

    @Test func onlyConfirmedAccountMayReadStoredHistoryWhileOffline() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant)
            var reads = 0
            let workspace = model(state, store: store, read: { reads += 1; return history() })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true); await workspace.importHistory()
            state.connected = false; workspace.restore()
            await workspace.importHistory()
            #expect(workspace.sources.count == 2); #expect(!workspace.mayImport); #expect(reads == 1)
            state.current = nil
            #expect(workspace.sources.isEmpty); #expect(workspace.importedAt == nil)
        }
    }

    @Test(arguments: ["account", "credential", "assignment", "lock", "invalidate", "cancel", "offline"])
    func delayedImportCannotSurviveItsAccessBoundary(change: String) async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant), gate = PersonalHealthTestGate()
            let workspace = model(state, store: store, read: { await gate.wait(); return history() })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true)
            let task = Task { await workspace.importHistory() }
            await gate.held()
            switch change {
            case "account": state.current = try access()
            case "credential": state.current = try access(identity: state.original.identity, credential: String(repeating: "b", count: 64))
            case "assignment": state.current = try access(identity: state.original.identity, connection: state.original.connectionID, assignment: 2)
            case "lock": state.unlocked = false
            case "invalidate": workspace.invalidate()
            case "cancel": task.cancel()
            default: state.connected = false
            }
            await gate.release(); await task.value
            #expect(try store.read()?.history == nil)
            #expect(workspace.history == nil)
        }
    }

    @Test func accountChangeDuringPermissionDialogPreventsTheReadAndPermissionReceipt() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant), gate = PersonalHealthTestGate()
            var reads = 0
            let workspace = model(state, store: store, authorize: { await gate.wait() }, read: { reads += 1; return history() })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true)
            let task = Task { await workspace.importHistory() }
            await gate.held(); state.current = nil; await gate.release(); await task.value
            #expect(reads == 0); #expect(try store.read()?.permissionRequested == false)
        }
    }

    @Test func forgetDuringReadCannotRestoreDeletedDataOrItsEnrollment() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant), gate = PersonalHealthTestGate()
            let workspace = model(state, store: store, read: { await gate.wait(); return history() })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true)
            let task = Task { await workspace.importHistory() }
            await gate.held(); workspace.forget(); await gate.release(); await task.value
            #expect(try store.read() == nil); #expect(workspace.history == nil); #expect(workspace.status == .consentRequired)
        }
    }

    @Test func anotherWorkspaceDeletingAndReenrollingRejectsOldImportRevision() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant), gate = PersonalHealthTestGate()
            let workspace = model(state, store: store, read: { await gate.wait(); return history() })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true)
            let task = Task { await workspace.importHistory() }
            await gate.held()
            let saved = try #require(try store.read())
            try store.remove(identity: state.original.identity, expectedRevision: saved.revision)
            let fresh = try store.enroll(identity: state.original.identity, at: instant)
            await gate.release(); await task.value
            #expect(try store.read() == fresh); #expect(workspace.status == .unavailable)
        }
    }

    @Test func emptySuccessfulReadWithdrawsPreviousRecordsButFailurePreservesThem() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant)
            let source = PersonalHealthTestSource(history())
            let workspace = model(state, store: store, read: { if source.fail { throw PersonalHealthFailure.storage }; return source.history })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true); await workspace.importHistory()
            source.fail = true; await workspace.importHistory(requestPermission: false)
            #expect(workspace.sources.count == 2)
            source.fail = false; source.history = history(sources: 0); await workspace.importHistory(requestPermission: false)
            #expect(workspace.sources.isEmpty); #expect(workspace.importedAt == instant)
            #expect(workspace.message?.contains("no records or no permission") == true)
        }
    }

    @Test func sourceSelectionPersistsAndDisappearingSourceDoesNotCombineSources() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant)
            let source = PersonalHealthTestSource(history())
            let workspace = model(state, store: store, read: { source.history })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true); await workspace.importHistory()
            workspace.selectSource("source-1"); workspace.restore()
            #expect(workspace.selectedSource == "source-1")
            workspace.selectSource("unknown"); #expect(workspace.selectedSource == "source-1")
            source.history = history(sources: 1); await workspace.importHistory(requestPermission: false)
            #expect(workspace.selectedSource == "source-0"); #expect(workspace.sources.first?.recordedDays == 1)
        }
    }

    @Test func automaticRefreshNeedsOptInAndNeverRequestsPermission() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant)
            var reads = 0, permissions = 0
            let workspace = model(state, store: store, authorize: { permissions += 1 }, read: {
                reads += 1; var value = history(); value.importedAt = state.now; return value
            })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true); workspace.setAutomaticRefresh(true)
            await workspace.refreshOnActivation(); #expect(reads == 0)
            await workspace.importHistory(); workspace.setAutomaticRefresh(true)
            await workspace.refreshOnActivation(); #expect(reads == 1)
            state.now = instant.addingTimeInterval(86_400)
            await workspace.refreshOnActivation()
            #expect(reads == 2); #expect(permissions == 1)
            workspace.setAutomaticRefresh(false); state.now = state.now.addingTimeInterval(86_400)
            await workspace.refreshOnActivation(); #expect(reads == 2)
        }
    }

    @Test func unreadableArchiveIsNeverOverwrittenByEnrollmentOrImport() async throws {
        try await personal {
            let (directory, store, snapshots) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            try snapshots.write(["bad": "shape"], scope: "device-health-enrollment")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let file = try #require(files.first)
            let original = try Data(contentsOf: file)
            let state = PersonalHealthTestState(try access(), now: instant)
            var reads = 0
            let workspace = model(state, store: store, read: { reads += 1; return history() })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true); await workspace.importHistory()
            #expect(workspace.status == .unavailable); #expect(reads == 0); #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test(arguments: ["future", "overlap", "negative", "duplicate", "timezone", "stage"])
    func invalidImportCannotReplaceValidHistory(change: String) async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant)
            let source = PersonalHealthTestSource(history())
            let workspace = model(state, store: store, read: { source.history })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true); await workspace.importHistory()
            let original = try store.read()
            switch change {
            case "future": source.history.importedAt = instant.addingTimeInterval(1000)
            case "overlap": source.history.sources[0].nights[0].asleepMinutes = 1000
            case "negative": source.history.ignoredSamples = -1
            case "duplicate": source.history.sources.append(source.history.sources[0])
            case "timezone": source.history.timeZone = "missing-zone"
            default: source.history.sources[0].nights[0].deepMinutes = 400; source.history.sources[0].nights[0].remMinutes = 300
            }
            await workspace.importHistory(requestPermission: false)
            #expect(try store.read() == original); #expect(workspace.history == history())
        }
    }

    @Test func ciphertextContainsNoIdentifiersOrReadableHealthAndUsesCorrectNamespace() throws {
        let (directory, store, snapshots) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let person = identity()
        _ = try store.enroll(identity: person, at: instant)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        let contents = try Data(contentsOf: file)
        #expect(contents.range(of: Data(person.accountID.uuidString.utf8)) == nil)
        #expect(try snapshots.read(PersonalHealthArchive.self, scope: "device-owner") == nil)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func ownerAndDemoModesCannotOpenPersonalHealthEvenWithMatchingGrant() async throws {
        let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = PersonalHealthTestState(try access(), now: instant)
        for (backend, personalMode) in [("sleepypod-core", false), ("demo", true)] {
            await AppMode.$suppliedBackend.withValue(backend) {
                await PersonalWorkspaceBoundary.$suppliedActive.withValue(personalMode) {
                    let workspace = model(state, store: store, read: { history() })
                    workspace.restore(); workspace.enroll(confirmedOwnHealth: true); await workspace.importHistory()
                    #expect(workspace.status == .invalidated); #expect(workspace.sources.isEmpty)
                }
            }
        }
        #expect(try store.read() == nil)
    }

    @Test func revocationRemovesOnlyMatchingPersonalIdentityAndExplicitEraseCanClearCorruption() throws {
        let (directory, store, snapshots) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = try store.enroll(identity: identity(), at: instant)
        try snapshots.write(["owner": "unchanged"], scope: "device-owner")
        try PersonalHealthWorkspace.removeLocalData(for: identity(), snapshots: snapshots)
        #expect(try store.read() == original)
        try PersonalHealthWorkspace.removeLocalData(for: original.identity, snapshots: snapshots)
        #expect(try store.read() == nil)
        try snapshots.write(["corrupt": true], scope: "device-health-enrollment")
        try PersonalHealthWorkspace.eraseAllLocalData(snapshots: snapshots)
        #expect(try store.read() == nil)
        #expect(try snapshots.read([String: String].self, scope: "device-owner") == ["owner": "unchanged"])
    }

    @Test func cancelStopsTheUnderlyingCooperativeHealthRead() async throws {
        try await personal {
            let (directory, store, _) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let state = PersonalHealthTestState(try access(), now: instant), gate = PersonalHealthTestGate()
            let source = PersonalHealthTestSource(history())
            let workspace = model(state, store: store, read: {
                await gate.wait()
                source.fail = Task.isCancelled
                try Task.checkCancellation()
                return source.history
            })
            workspace.restore(); workspace.enroll(confirmedOwnHealth: true)
            let task = Task { await workspace.importHistory() }
            await gate.held(); workspace.cancelImport(); await gate.release(); await task.value
            #expect(source.fail); #expect(try store.read()?.history == nil)
            #expect(workspace.message?.contains("cancelled") == true)
        }
    }
}

@MainActor private final class PersonalHealthTestState {
    let original: PersonalHealthAccess
    var current: PersonalHealthAccess?
    var unlocked = true
    var connected = true
    var now: Date
    init(_ access: PersonalHealthAccess, now: Date) { original = access; current = access; self.now = now }
}

@MainActor private final class PersonalHealthTestSource {
    var history: HealthHistory
    var fail = false
    init(_ history: HealthHistory) { self.history = history }
}

private actor PersonalHealthTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func held() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
