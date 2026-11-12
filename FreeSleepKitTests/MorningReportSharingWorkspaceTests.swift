import Foundation
import Testing
@testable import FreeSleepKit

@MainActor struct MorningReportSharingWorkspaceTests {
    private let now = Date(timeIntervalSince1970: 1_793_635_600)
    private func report() -> PersonalSleepReport {
        .init(id: UUID(), createdAt: now.addingTimeInterval(-100), provider: .apple, model: "fixture-local", source: "Synthetic source",
              facts: [.init(id: "health.sleep", text: "Synthetic saved evidence")], text: "A synthetic report.")
    }
    private func shared(_ report: PersonalSleepReport, deleted: Bool = false) throws -> MorningReportSharedCopy {
        let timestamp = Int64(now.timeIntervalSince1970 * 1000)
        return .init(receipt: .init(id: report.id, revision: UUID(), deleted: deleted,
            createdAt: Int64(report.createdAt.timeIntervalSince1970 * 1000), receivedAt: timestamp, updatedAt: timestamp),
            document: deleted ? nil : try MorningReportTransfer.document(report, now: now))
    }
    private func workspace(_ transport: ReportSharingFake, current: @escaping @MainActor () -> Bool = { true },
                           protected: @escaping @MainActor () -> Bool = { true }) -> MorningReportSharingWorkspace {
        let now = now
        return .init(connect: { .init(address: "https://fixture.invalid", transport: transport, isCurrent: current) },
                     protectedData: protected, now: { now })
    }

    @Test func readingAndSharingRequireSeparateExplicitConsent() async throws {
        let transport = ReportSharingFake(), workspace = workspace(transport), report = report()
        await workspace.refresh(report)
        #expect(workspace.status == .notShared); #expect(workspace.canShare)
        await workspace.share(consent: false)
        #expect(await transport.actions == ["read"])
        try await transport.configure(shared: shared(report))
        await workspace.share(consent: true)
        #expect(workspace.status == .shared); #expect(!workspace.canShare); #expect(workspace.canWithdraw)
        #expect(await transport.actions == ["read", "share"])
        try await transport.configure(read: shared(report))
        workspace.suspend(); await workspace.refresh(report)
        #expect(await transport.actions == ["read", "share", "read"])
    }

    @Test func uncertainUploadIsReadBeforeAnyFurtherSharingAndCanBeWithdrawn() async throws {
        let transport = ReportSharingFake(), workspace = workspace(transport), report = report()
        await workspace.refresh(report)
        await transport.configure(failure: .uncertain)
        await workspace.share(consent: true)
        #expect(workspace.status == .uncertain); #expect(!workspace.canShare); #expect(workspace.canWithdraw)
        await workspace.share(consent: true)
        #expect(await transport.actions == ["read", "share"])
        try await transport.configure(removed: shared(report, deleted: true))
        await workspace.withdraw()
        #expect(workspace.status == .withdrawn); #expect(!workspace.canShare); #expect(!workspace.canWithdraw)
        #expect(await transport.lastExpectedRevision == nil)
    }

    @Test func identityChangeOrLockDiscardsDelayedReadsAndMutations() async throws {
        for change in ["identity", "lock", "suspend"] {
            let access = SharingAccess()
            let transport = ReportSharingFake(), report = report()
            let workspace = workspace(transport, current: { access.current }, protected: { access.unlocked })
            await workspace.refresh(report)
            try await transport.configure(shared: shared(report), delay: true)
            let task = Task { await workspace.share(consent: true) }
            await transport.waitUntilPaused()
            switch change {
            case "identity": access.current = false
            case "lock": access.unlocked = false
            default: workspace.suspend()
            }
            await transport.resume(); await task.value
            #expect(workspace.status == .unchecked); #expect(workspace.receipt == nil)
            #expect(workspace.address == nil); #expect(!workspace.canShare)
            #expect(await transport.actions == ["read", "share"])
        }
    }

    @Test func existingWebAnswersCannotBeReplacedByAnOlderPhoneCopy() async throws {
        let report = report()
        var newer = report
        newer.followUps = [.init(id: UUID(), createdAt: now.addingTimeInterval(-10), question: "A saved question?",
            text: "An answer based on the same facts.", provider: .apple, model: "fixture-local")]
        let transport = ReportSharingFake(), workspace = workspace(transport)
        try await transport.configure(read: shared(newer))
        await workspace.refresh(report)
        #expect(workspace.status == .shared); #expect(!workspace.canShare); #expect(workspace.canWithdraw)
        await workspace.share(consent: true)
        #expect(await transport.actions == ["read"])
        try await transport.configure(read: shared(report))
        await workspace.refresh(newer)
        #expect(workspace.status == .shared); #expect(workspace.needsUpdate); #expect(workspace.canShare)
    }

    @Test func originalEvidenceOrAnswerChangesAreConflictsNotAReplacement() throws {
        let original = report()
        var changed = original; changed.facts[0].text = "Different evidence"
        #expect(try MorningReportTransfer.relationship(local: MorningReportTransfer.document(original, now: now),
            shared: MorningReportTransfer.document(changed, now: now)) == .different)
        var withAnswer = original
        withAnswer.followUps = [.init(id: UUID(), createdAt: now.addingTimeInterval(-5), question: "Why?", text: "Saved answer", provider: .apple, model: "fixture")]
        changed = withAnswer; changed.followUps?[0].text = "Rewritten answer"
        #expect(try MorningReportTransfer.relationship(local: MorningReportTransfer.document(withAnswer, now: now),
            shared: MorningReportTransfer.document(changed, now: now)) == .different)
    }

    @Test func revokedIdentityOrWithdrawnCopyNeverUploads() async throws {
        let access = SharingAccess()
        let transport = ReportSharingFake(), report = report(), workspace = workspace(transport, current: { access.current })
        await workspace.refresh(report); access.current = false
        await workspace.share(consent: true); await workspace.withdraw()
        #expect(await transport.actions == ["read"])
        access.current = true
        try await transport.configure(read: shared(report, deleted: true))
        await workspace.refresh(report); await workspace.share(consent: true)
        #expect(workspace.status == .withdrawn)
        #expect(await transport.actions == ["read", "read"])
    }
}

@MainActor private final class SharingAccess {
    var current = true
    var unlocked = true
}

private actor ReportSharingFake: MorningReportSharingTransport {
    var actions: [String] = []
    var lastExpectedRevision: UUID?
    private var readValue: MorningReportSharedCopy?
    private var sharedValue: MorningReportSharedCopy?
    private var removedValue: MorningReportSharedCopy?
    private var failure: MorningReportSharingFailure?
    private var delay = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func configure(read: MorningReportSharedCopy? = nil, shared: MorningReportSharedCopy? = nil,
                   removed: MorningReportSharedCopy? = nil, failure: MorningReportSharingFailure? = nil, delay: Bool = false) {
        readValue = read; sharedValue = shared; removedValue = removed; self.failure = failure; self.delay = delay
    }
    func read(id: UUID) async throws -> MorningReportSharedCopy? { actions.append("read"); return readValue }
    func share(id: UUID, document: Data, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        actions.append("share"); lastExpectedRevision = expectedRevision
        if delay { await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil } }
        if let failure { throw failure }
        guard let sharedValue else { throw MorningReportSharingFailure.invalid }; return sharedValue
    }
    func withdraw(id: UUID, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        actions.append("withdraw"); lastExpectedRevision = expectedRevision
        guard let removedValue else { throw MorningReportSharingFailure.invalid }; return removedValue
    }
    func waitUntilPaused() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
