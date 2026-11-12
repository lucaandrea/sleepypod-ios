import CryptoKit
import Foundation
import Security
import Testing
@testable import FreeSleepKit

@MainActor struct PersonalReportEnrollmentTests {
    @Test func catalogUsesOnlyPersonalKeyAndNeverSendsHealthOrCreatesAReport() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(); await fixture.model.refreshModels()
        let request = try #require(await fixture.transport.catalogRequests.first)
        #expect(request.provider == .openai); #expect(request.key == "fixture-personal-key"); #expect(request.address.isEmpty)
        #expect(fixture.model.models.contains("account-model")); #expect(!fixture.model.models.contains("bad model\n"))
        #expect(fixture.model.records.isEmpty); #expect(fixture.model.attempts == 0)
        #expect(await fixture.transport.requests.isEmpty)
    }

    @Test(arguments: ["account", "lock", "cancel", "offline"])
    func delayedCatalogCannotSurviveAccessChanges(change: String) async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(); await fixture.transport.hold()
        let pending = Task { await fixture.model.refreshModels() }
        await fixture.transport.waitUntilHeld()
        switch change {
        case "account": fixture.state.current = nil
        case "lock": fixture.state.unlocked = false
        case "cancel": fixture.model.cancel()
        default: fixture.state.permitted = false
        }
        await fixture.transport.release(); await pending.value
        #expect(!fixture.model.models.contains("account-model")); #expect(fixture.model.records.isEmpty)
        if change == "cancel" { #expect(await fixture.transport.wasCancelled) }
    }

    @Test func separateAccountsNeverReadOwnerReportsPreferencesOrKeys() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        try fixture.snapshots.write(["owner": "private owner report"], scope: "device-owner")
        fixture.model.restore()
        #expect(fixture.model.preferences.provider == .apple)
        fixture.model.prepare(question: "Summarize my records")
        await fixture.model.generate(confirmedSharing: false)
        #expect(fixture.model.records.count == 1)
        let second = try PersonalReportFixture(snapshots: fixture.snapshots); defer { second.cleanup() }
        second.model.restore()
        #expect(second.model.records.isEmpty); #expect(second.model.preferences.provider == .apple)
        #expect(try fixture.store.read(fixture.state.access.identity)?.records.count == 1)
        #expect(try fixture.snapshots.read([String: String].self, scope: "device-owner")?["owner"] == "private owner report")
    }

    @Test func reportReviewFreezesEvidenceAndDoesNotSendUntilConfirmed() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud()
        fixture.model.prepare(question: "Why was my recorded sleep shorter?")
        let review = try #require(fixture.model.review)
        #expect(review.facts == fixture.state.health?.facts)
        await fixture.model.generate(confirmedSharing: false)
        #expect(await fixture.transport.requests.isEmpty); #expect(fixture.model.records.isEmpty)
        await fixture.model.generate(confirmedSharing: true)
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.key == "fixture-personal-key")
        #expect(request.prompt.contains("account-only observation")); #expect(!request.prompt.contains("raw sample"))
        #expect(!request.prompt.contains(request.key)); #expect(request.instructions == PersonalReportPrompt.instructions)
        let record = try #require(fixture.model.records.first)
        #expect(record.permission.destination == IntelligenceProvider.openai.title)
        #expect(record.permission.leavesDevice); #expect(record.report.facts == review.facts)
        #expect(fixture.model.review == nil); #expect(fixture.model.attempts == 1)
    }

    @Test(arguments: ["expired", "source", "account", "settings", "offline", "protected", "wrong-evidence-owner"])
    func invalidReviewCannotSend(change: String) async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(); fixture.model.prepare(question: "Review this source")
        switch change {
        case "expired": fixture.state.now = fixture.state.now.addingTimeInterval(301)
        case "source": fixture.state.healthCurrent = false
        case "account": fixture.state.current = nil
        case "settings":
            var preferences = fixture.model.preferences; preferences.model = "another-model"; fixture.model.configure(preferences)
        case "offline": fixture.state.permitted = false
        case "protected": fixture.state.unlocked = false
        default:
            fixture.state.health = PersonalReportFixture.evidence(identity: PersonalReportFixture.identity(), at: fixture.state.now)
            fixture.model.discardReview(); fixture.model.prepare(question: "Review this source")
        }
        await fixture.model.generate(confirmedSharing: true)
        #expect(await fixture.transport.requests.isEmpty)
        #expect(try fixture.store.read(fixture.state.access.identity)?.records.isEmpty == true)
    }

    @Test(arguments: ["account", "credential", "assignment", "lock", "mode", "offline", "health", "erase", "cancel"])
    func delayedModelCannotWriteAcrossAnAccessOrDataBoundary(change: String) async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(); fixture.model.prepare(question: "Make a report")
        await fixture.transport.hold()
        let request = Task { await fixture.model.generate(confirmedSharing: true) }
        await fixture.transport.waitUntilHeld()
        switch change {
        case "account": fixture.state.current = nil
        case "credential": fixture.state.current = try fixture.state.revised(credential: String(repeating: "b", count: 64))
        case "assignment": fixture.state.current = try fixture.state.revised(assignment: 2)
        case "lock": fixture.state.unlocked = false
        case "mode": fixture.state.personal = false
        case "offline": fixture.state.permitted = false
        case "health": fixture.state.healthCurrent = false
        case "erase": try fixture.store.remove(fixture.state.access.identity)
        default: fixture.model.cancel()
        }
        await fixture.transport.release(); await request.value
        #expect(try fixture.store.read(fixture.state.access.identity)?.records.isEmpty != false)
        #expect(fixture.model.records.isEmpty)
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test func cancellationCancelsUnderlyingRequestAndNeverRetries() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(); fixture.model.prepare(question: "Make a report")
        await fixture.transport.hold()
        let request = Task { await fixture.model.generate(confirmedSharing: true) }
        await fixture.transport.waitUntilHeld(); request.cancel()
        await fixture.transport.release(); await request.value
        #expect(await fixture.transport.wasCancelled)
        #expect(fixture.model.records.isEmpty); #expect(fixture.model.attempts == 1)
        await fixture.model.generate(confirmedSharing: true)
        #expect(await fixture.transport.requests.count == 1)
    }

    @Test func followUpUsesOriginalFactsAndNeedsSeparateConsent() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(); fixture.model.prepare(question: "Create report"); await fixture.model.generate(confirmedSharing: true)
        let original = try #require(fixture.model.records.first)
        fixture.state.health = nil
        fixture.model.prepare(question: "What does that mean?", reportID: original.id)
        #expect(fixture.model.review?.facts == original.report.facts)
        await fixture.model.generate(confirmedSharing: false)
        #expect(await fixture.transport.requests.count == 1)
        await fixture.model.generate(confirmedSharing: true)
        let updated = try #require(fixture.model.records.first)
        #expect(updated.report.facts == original.report.facts); #expect(updated.report.text == original.report.text)
        #expect(updated.report.followUps?.count == 1); #expect(updated.answerPermissions.count == 1)
        #expect(await fixture.transport.requests.last?.prompt.contains("original calculated facts") == true)
        #expect(fixture.model.attempts == 2)
    }

    @Test func forgetDoesNotResetRequestLimitAndLateResponseCannotRestoreDeletedReports() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(limit: 1); fixture.model.prepare(question: "Create report")
        await fixture.model.generate(confirmedSharing: true)
        fixture.model.forgetReports(); #expect(fixture.model.records.isEmpty); #expect(fixture.model.attempts == 1)
        fixture.model.prepare(question: "Another report"); await fixture.model.generate(confirmedSharing: true)
        #expect(await fixture.transport.requests.count == 1)
        #expect(fixture.model.message == PersonalReportFailure.limit.localizedDescription)
    }

    @Test func modelTestIncludesNoHealthEvidenceAndCountsFailedRequests() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud()
        await fixture.transport.fail()
        await fixture.model.testModel()
        let request = try #require(await fixture.transport.requests.first)
        #expect(request.diagnostic); #expect(!request.prompt.contains("account-only"))
        #expect(fixture.model.attempts == 1); #expect(fixture.model.records.isEmpty)
        #expect(fixture.model.message?.contains("fixture-personal-key") != true)
    }

    @Test func lateErrorIsHiddenAfterAccountChange() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.cloud(); fixture.model.prepare(question: "Create report")
        await fixture.transport.hold(); await fixture.transport.fail()
        let request = Task { await fixture.model.generate(confirmedSharing: true) }
        await fixture.transport.waitUntilHeld(); fixture.state.current = nil
        await fixture.transport.release(); await request.value
        #expect(fixture.model.message == nil); #expect(fixture.model.review == nil); #expect(fixture.model.records.isEmpty)
    }

    @Test func offlineRetainedIdentityReadsOnlyItsSavedReports() async throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        fixture.model.restore(); fixture.model.prepare(question: "Create report"); await fixture.model.generate(confirmedSharing: false)
        fixture.state.permitted = false; fixture.model.restore()
        #expect(fixture.model.records.count == 1); #expect(!fixture.model.mayRequest)
        fixture.state.current = nil; #expect(fixture.model.records.isEmpty)
    }

    @Test func unreadableStoreIsNotOverwrittenAndWrongIdentityArchiveIsRejected() throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        try fixture.snapshots.write(["version": 999], scope: fixture.state.access.identity.reportScope)
        fixture.model.restore(); fixture.model.configure(.init()); fixture.model.prepare(question: "Create")
        #expect(!fixture.model.available); #expect(fixture.model.review == nil)
        #expect(try fixture.snapshots.read([String: Int].self, scope: fixture.state.access.identity.reportScope) == ["version": 999])
        try fixture.snapshots.write(PersonalReportArchive(identity: PersonalReportFixture.identity()), scope: fixture.state.access.identity.reportScope)
        #expect(throws: PersonalReportFailure.invalid) { try fixture.store.read(fixture.state.access.identity) }
    }

    @Test func staleArchiveRevisionCannotRestoreAfterDeleteAndReopen() throws {
        let fixture = try PersonalReportFixture(); defer { fixture.cleanup() }
        let old = try fixture.store.open(fixture.state.access.identity)
        try fixture.store.remove(old.identity)
        let fresh = try fixture.store.open(old.identity)
        #expect(old.revision != fresh.revision)
        #expect(throws: PersonalReportFailure.changed) { try fixture.store.update(old, expectedRevision: old.revision) }
    }

    @Test func keychainQueriesSeparateProvidersPeopleAndOwnerService() throws {
        let identity = PersonalReportFixture.identity()
        let first = PersonalProviderKeychain(identity: identity)
        let second = PersonalProviderKeychain(identity: PersonalReportFixture.identity())
        let query = first.query(.openai)
        #expect(query[kSecAttrService as String] as? String != "com.lucaandrea.freesleep.model-keys")
        #expect(query[kSecAttrAccount as String] as? String != second.query(.openai)[kSecAttrAccount as String] as? String)
        #expect(query[kSecAttrAccount as String] as? String != first.query(.gemini)[kSecAttrAccount as String] as? String)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }
}
