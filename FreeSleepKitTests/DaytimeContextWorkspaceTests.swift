import CryptoKit
import Foundation
import Testing
@testable import FreeSleepKit

@MainActor struct DaytimeContextWorkspaceTests {
    private func real(_ body: @MainActor () async throws -> Void) async rethrows {
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            try await PersonalWorkspaceBoundary.$suppliedActive.withValue(false, operation: body)
        }
    }
    private func fixture() -> (URL, DaytimeContextStore) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        return (directory, .init(snapshots: .init(directory: directory, namespace: "context-test", encryptionKey: { key })))
    }
    private func snapshot() -> DaytimeContext {
        let end = Date.now.addingTimeInterval(-60)
        return .init(importedAt: end, timeZone: "America/Los_Angeles", reads: DaytimeContext.Kind.allCases.map {
            .init(kind: $0, state: .completed, start: end.addingTimeInterval(-90 * 86_400), end: end)
        }, observations: [])
    }
    @Test func noReadUntilExplicitOptInThenAutomaticReadNeverRequestsPermission() async throws {
        try await real {
            let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            var reads = 0, authorizations = 0
            let model = DaytimeContextWorkspace(store: store, readContext: { reads += 1; return snapshot() },
                authorize: { authorizations += 1 }, protectedDataAvailable: { true }, scope: { "owner-a" })
            await model.refreshOnActivation(); await model.importContext(requestPermission: false)
            #expect(reads == 0); #expect(!model.archive.enabled)
            await model.importContext(requestPermission: true)
            #expect(reads == 1); #expect(authorizations == 1); #expect(model.archive.enabled)
            let persisted = try store.read(scope: "owner-a")
            #expect(persisted == model.archive)
            await model.importContext(requestPermission: false)
            #expect(reads == 2); #expect(authorizations == 1)
        }
    }
    @Test func scopeSwitchImmediatelyHidesHistoryAndLateReadCannotWrite() async throws {
        try await real {
            let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            let saved = DaytimeContextArchive(enabled: true, snapshot: snapshot())
            try store.write(saved, scope: "owner-a")
            let gate = DaytimeContextGate(), state = DaytimeContextState()
            let model = DaytimeContextWorkspace(store: store, readContext: { await gate.wait(); return snapshot() },
                authorize: {}, protectedDataAvailable: { true }, scope: { state.scope })
            model.restore(); #expect(model.archive == saved)
            let operation = Task { await model.importContext(requestPermission: false) }
            await gate.held(); state.scope = "owner-b"
            #expect(model.archive.snapshot == nil); #expect(model.message == nil)
            model.restore(); await gate.release(); await operation.value
            #expect(model.archive.snapshot == nil)
            #expect(try store.read(scope: "owner-a") == saved)
            #expect(try store.read(scope: "owner-b").snapshot == nil)
        }
    }
    @Test func lockCancellationAndSuspensionCannotCommitLateResult() async throws {
        for change in ["lock", "cancel", "suspend"] {
            try await real {
                let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
                let gate = DaytimeContextGate(), state = DaytimeContextState()
                let model = DaytimeContextWorkspace(store: store, readContext: { await gate.wait(); return snapshot() },
                    authorize: {}, protectedDataAvailable: { state.unlocked }, scope: { state.scope })
                let operation = Task { await model.importContext(requestPermission: true) }
                await gate.held()
                if change == "lock" { state.unlocked = false }
                else if change == "cancel" { operation.cancel() }
                else { model.suspend() }
                await gate.release(); await operation.value
                #expect(model.archive.snapshot == nil)
                let persisted = try store.read(scope: state.scope)
                #expect(persisted.snapshot == nil)
            }
        }
    }
    @Test func deleteDuringImportInvalidatesTheReadAndDisablesRefresh() async throws {
        try await real {
            let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            try store.write(.init(enabled: true, snapshot: snapshot()), scope: "owner-a")
            let gate = DaytimeContextGate()
            let model = DaytimeContextWorkspace(store: store, readContext: { await gate.wait(); return snapshot() },
                authorize: {}, protectedDataAvailable: { true }, scope: { "owner-a" })
            let operation = Task { await model.importContext(requestPermission: false) }
            await gate.held(); model.forget(); await gate.release(); await operation.value
            #expect(!model.archive.enabled); #expect(model.archive.snapshot == nil)
            #expect(try store.read(scope: "owner-a").snapshot == nil)
        }
    }
    @Test func successfulEmptyReadWithdrawsRecordsAndFailurePreservesLastReceipt() async throws {
        try await real {
            let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            var previous = snapshot()
            previous.observations = [.init(id: UUID(), kind: .steps, source: .init(identifier: "example", name: "Example"),
                start: previous.importedAt.addingTimeInterval(-100), end: previous.importedAt, value: 20)]
            try store.write(.init(enabled: true, snapshot: previous), scope: "owner-a")
            let state = DaytimeContextState()
            let empty = snapshot()
            let model = DaytimeContextWorkspace(store: store, readContext: {
                if state.fail { throw DaytimeContextError.unavailable }; return empty
            }, protectedDataAvailable: { true }, scope: { "owner-a" })
            await model.importContext(requestPermission: false)
            #expect(model.archive.snapshot?.observations == [])
            #expect(model.message?.contains("does not reveal") == true)
            state.fail = true; await model.importContext(requestPermission: false)
            #expect(try store.read(scope: "owner-a").snapshot == empty)
            #expect(model.message?.contains("previous import is unchanged") == true)
        }
    }
    @Test func corruptArchiveCannotBeOverwrittenAndOtherIdentityStillHasNoData() async throws {
        try await real {
            let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            try store.write(.init(enabled: true, snapshot: snapshot()), scope: "owner-a")
            let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            let corrupt = Data("invalid sealed archive".utf8); try corrupt.write(to: file)
            var reads = 0
            let model = DaytimeContextWorkspace(store: store, readContext: { reads += 1; return snapshot() },
                authorize: {}, protectedDataAvailable: { true }, scope: { "owner-a" })
            await model.importContext(requestPermission: true)
            #expect(reads == 0); #expect(try Data(contentsOf: file) == corrupt)
            #expect(try store.read(scope: "owner-b").snapshot == nil)
        }
    }
    @Test func demoPersonalWorkspaceAndLockedDeviceCannotReadHealth() async throws {
        let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var reads = 0, authorizations = 0
        let state = DaytimeContextState()
        let model = DaytimeContextWorkspace(store: store, readContext: { reads += 1; return snapshot() },
            authorize: { authorizations += 1 }, protectedDataAvailable: { state.unlocked }, scope: { "owner-a" })
        await AppMode.$suppliedBackend.withValue("demo") { await model.importContext(requestPermission: true) }
        await PersonalWorkspaceBoundary.$suppliedActive.withValue(true) { await model.importContext(requestPermission: true) }
        state.unlocked = false
        await real { await model.importContext(requestPermission: true) }
        #expect(reads == 0); #expect(authorizations == 0)
    }
    @Test func explicitRemovalRecoversUnreadableArchiveWithoutTouchingOtherOwner() async throws {
        try await real {
            let (directory, store) = fixture(); defer { try? FileManager.default.removeItem(at: directory) }
            try store.write(.init(enabled: true, snapshot: snapshot()), scope: "owner-a")
            let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            try Data("invalid archive".utf8).write(to: file)
            let other = DaytimeContextArchive(enabled: true, snapshot: snapshot())
            try store.write(other, scope: "owner-b")
            let model = DaytimeContextWorkspace(store: store, readContext: { snapshot() }, authorize: {},
                protectedDataAvailable: { true }, scope: { "owner-a" })
            model.restore(); #expect(model.canRemoveLocalCopy)
            model.forget(); #expect(!model.canRemoveLocalCopy)
            #expect(try store.read(scope: "owner-a").snapshot == nil)
            #expect(try store.read(scope: "owner-b") == other)
            await model.importContext(requestPermission: true)
            #expect(model.archive.enabled); #expect(model.archive.snapshot != nil)
        }
    }
}

@MainActor private final class DaytimeContextState { var scope = "owner-a"; var unlocked = true; var fail = false }
private actor DaytimeContextGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func held() async { while !entered { await Task.yield() } }
    func release() { waiting?.resume(); waiting = nil }
}
