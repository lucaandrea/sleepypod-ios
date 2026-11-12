import Foundation
import Observation
import UIKit

struct PersonalReportReview: Equatable {
    let id: UUID
    let expiresAt: Date
    let preferences: PersonalReportPreferences
    let archiveRevision: UUID
    let question: String
    let facts: [SleepFact]
    let source: String
    let comparison: ReportSleepComparison?
    let health: PersonalReportEvidence?
    let previous: PersonalReportRecord?
}

/// Personal reporting has its own encrypted archive, Keychain scope and per-request consent.
@MainActor @Observable public final class PersonalReportWorkspace {
    public let access: PersonalHealthAccess
    public let displayName: String
    private var archive: PersonalReportArchive?
    private var storedReview: PersonalReportReview?
    private var storedMessage: String?
    private var storedBusy = false
    private var storedCatalog: [String] = []
    private var invalidated = false
    private var operation = UUID()
    private var requestTask: Task<ModelReply, Error>?
    private var catalogTask: Task<[String], Error>?
    private let currentAccess: @MainActor () -> PersonalHealthAccess?
    private let requestPermitted: @MainActor () -> Bool
    private let protectedData: @MainActor () -> Bool
    private let allowedMode: @MainActor () -> Bool
    private let evidence: @MainActor (Date) -> PersonalReportEvidence?
    private let evidenceCurrent: @MainActor (PersonalReportEvidence) -> Bool
    private let store: PersonalReportStore
    private let keys: any PersonalProviderKeys
    private let generateModel: @Sendable (ModelRequest) async throws -> ModelReply
    private let listModels: @Sendable (IntelligenceProvider, String, String) async throws -> [String]
    private let now: @MainActor () -> Date

    public convenience init(health: PersonalHealthWorkspace,
                            currentAccess: @escaping @MainActor () -> PersonalHealthAccess?,
                            requestPermitted: @escaping @MainActor () -> Bool, snapshots: PrivateSnapshotStore? = nil) {
        self.init(access: health.access, displayName: health.displayName, currentAccess: currentAccess,
                  requestPermitted: requestPermitted, store: .init(snapshots: snapshots), keys: PersonalProviderKeychain(identity: health.access.identity),
                  evidence: { [weak health] in health?.reportEvidence(at: $0) },
                  evidenceCurrent: { [weak health] in health?.reportEvidenceIsCurrent($0) == true })
    }

    init(access: PersonalHealthAccess, displayName: String,
         currentAccess: @escaping @MainActor () -> PersonalHealthAccess?,
         requestPermitted: @escaping @MainActor () -> Bool, store: PersonalReportStore, keys: any PersonalProviderKeys,
         evidence: @escaping @MainActor (Date) -> PersonalReportEvidence?,
         evidenceCurrent: @escaping @MainActor (PersonalReportEvidence) -> Bool,
         protectedData: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
         allowedMode: @escaping @MainActor () -> Bool = { !AppMode.isDemo && PersonalWorkspaceBoundary.isActive },
         generateModel: @escaping @Sendable (ModelRequest) async throws -> ModelReply = { try await NativeModelClient().generate($0) },
         listModels: @escaping @Sendable (IntelligenceProvider, String, String) async throws -> [String] = {
             try await ProviderCatalog().models(provider: $0, key: $1, localAddress: $2)
         },
         now: @escaping @MainActor () -> Date = { .now }) {
        self.access = access; self.displayName = displayName; self.currentAccess = currentAccess
        self.requestPermitted = requestPermitted; self.store = store; self.keys = keys
        self.evidence = evidence; self.evidenceCurrent = evidenceCurrent
        self.protectedData = protectedData; self.allowedMode = allowedMode; self.generateModel = generateModel; self.now = now
        self.listModels = listModels
    }

    private var readable: Bool { !invalidated && allowedMode() && protectedData() && currentAccess() == access }
    public var isInvalidated: Bool { invalidated }
    public var busy: Bool { readable && storedBusy }
    public var message: String? { readable ? storedMessage : nil }
    public var available: Bool { readable && archive != nil }
    public var mayRequest: Bool { available && requestPermitted() && !storedBusy }
    var preferences: PersonalReportPreferences { readable ? archive?.preferences ?? .init() : .init() }
    var records: [PersonalReportRecord] { readable ? archive?.records ?? [] : [] }
    var review: PersonalReportReview? { readable ? storedReview : nil }
    var attempts: Int { readable && archive?.usageMonth == month ? archive?.attempts ?? 0 : 0 }
    var hasKey: Bool { readable && (try? keys.read(preferences.provider).isEmpty) == false }
    var hasHealthEvidence: Bool { readable && evidence(now()) != nil }
    var models: [String] {
        guard readable else { return [] }
        return Array(Set(preferences.provider.models + storedCatalog + [preferences.model])).sorted()
    }
    private var month: String { String(now().ISO8601Format().prefix(7)) }

    public func restore() {
        guard readable, !storedBusy else { return }
        archive = nil; storedReview = nil; storedMessage = nil; storedCatalog = []
        do { archive = try store.open(access.identity) }
        catch { storedMessage = PersonalReportFailure.storage.localizedDescription }
    }

    func configure(_ preferences: PersonalReportPreferences) {
        guard mayRequest, var saved = archive else { return }
        storedReview = nil; storedCatalog = []
        do {
            try preferences.validate(); saved.preferences = preferences
            archive = try store.update(saved, expectedRevision: saved.revision); storedMessage = nil
        } catch { storedMessage = PersonalReportFailure.invalid.localizedDescription }
    }

    func saveKey(_ value: String) {
        guard mayRequest else { return }; storedReview = nil
        do { try keys.save(value, for: preferences.provider); storedMessage = "Key saved for this personal account on this device." }
        catch { storedMessage = "The key could not be saved. Unlock this device and check that you pasted the complete key." }
    }

    func removeKey() {
        guard mayRequest else { return }; storedReview = nil
        do { try keys.remove(preferences.provider); storedMessage = "This personal account’s provider key was removed." }
        catch { storedMessage = PersonalReportFailure.storage.localizedDescription }
    }

    /// The review freezes the selected source or the original report, never another account's archive.
    func prepare(question: String, reportID: UUID? = nil) {
        guard mayRequest, let saved = archive else { return }
        storedReview = nil; storedMessage = nil
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 600 else { storedMessage = "Enter a question of up to 600 characters."; return }
        let previous = reportID.flatMap { identifier in saved.records.first { $0.id == identifier } }
        if reportID != nil, previous == nil || (previous?.report.followUps?.count ?? 0) >= 10 {
            storedMessage = "Reopen a saved report with fewer than ten answers."; return
        }
        let health = previous == nil ? evidence(now()) : nil
        guard previous != nil || (health?.identity == access.identity && health.map(evidenceCurrent) == true) else {
            storedMessage = PersonalReportFailure.evidence.localizedDescription; return
        }
        // Resolve the evidence before constructing the review so older supported compilers can type-check it.
        let facts: [SleepFact] = previous?.report.facts ?? health?.facts ?? []
        let source: String = previous?.report.source ?? health?.sourceName ?? ""
        let comparison: ReportSleepComparison? = previous?.report.comparison ?? health?.comparison
        storedReview = PersonalReportReview(id: UUID(), expiresAt: now().addingTimeInterval(300), preferences: saved.preferences,
                             archiveRevision: saved.revision, question: question,
                             facts: facts, source: source, comparison: comparison, health: health, previous: previous)
    }

    func discardReview() { storedReview = nil }

    func generate(confirmedSharing: Bool) async {
        guard mayRequest, let review = storedReview else { return }
        guard !review.preferences.provider.leavesDevice || confirmedSharing else {
            storedMessage = PersonalReportFailure.consent.localizedDescription; return
        }
        let identifier = UUID(); operation = identifier
        do {
            try checkReview(review)
            let permission = PersonalReportPermission(confirmedAt: now(), provider: review.preferences.provider,
                requestedModel: review.preferences.model, destination: review.preferences.destination,
                leavesDevice: review.preferences.provider.leavesDevice)
            let prompt = review.previous.map { PersonalReportPrompt.followUp(report: $0.report, question: review.question) }
                ?? PersonalReportPrompt.make(facts: review.facts, question: review.question)
            let request = try makeRequest(prompt: prompt, preferences: review.preferences)
            let reserved = try reserve()
            storedReview = nil; storedBusy = true; storedMessage = nil
            defer { if operation == identifier { storedBusy = false; requestTask = nil } }
            try checkOperation(identifier, revision: reserved.revision, health: review.health)
            let reply = try await run(request)
            try checkOperation(identifier, revision: reserved.revision, health: review.health)
            var updated = reserved
            try append(reply, review: review, permission: permission, to: &updated)
            archive = try store.update(updated, expectedRevision: reserved.revision)
            storedMessage = review.previous == nil ? "Report saved privately for this account on this device."
                : "Answer saved with the original report and its original evidence."
        } catch { finish(error, operation: identifier) }
    }

    func testModel() async {
        guard mayRequest else { return }
        let identifier = UUID(); operation = identifier; storedReview = nil
        do {
            let request = try makeRequest(prompt: "Reply with a short confirmation. No personal data is included.",
                                          preferences: preferences, diagnostic: true)
            let reserved = try reserve()
            storedBusy = true; storedMessage = nil
            defer { if operation == identifier { storedBusy = false; requestTask = nil } }
            try checkOperation(identifier, revision: reserved.revision, health: nil)
            let reply = try await run(request)
            try checkOperation(identifier, revision: reserved.revision, health: nil)
            storedMessage = "A response was received from \(reply.model). No Health or Pod evidence was sent."
        } catch { finish(error, operation: identifier) }
    }

    func refreshModels() async {
        guard mayRequest, preferences.provider != .apple, let saved = archive else { return }
        let identifier = UUID(); operation = identifier; storedReview = nil
        storedBusy = true; storedMessage = nil
        defer { if operation == identifier { storedBusy = false; catalogTask = nil } }
        do {
            let key = try keys.read(saved.preferences.provider)
            try checkOperation(identifier, revision: saved.revision, health: nil)
            let task = Task {
                try await listModels(saved.preferences.provider, key, saved.preferences.localAddress)
            }
            catalogTask = task
            let catalog = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try checkOperation(identifier, revision: saved.revision, health: nil)
            storedCatalog = Array(catalog.filter(IntelligenceProvider.validModel).prefix(3000))
            storedMessage = "Model list refreshed. Listing a model does not prove access; test your choice before creating a report."
        } catch { finish(error, operation: identifier) }
    }

    private func run(_ request: ModelRequest) async throws -> ModelReply {
        let task = Task { try await generateModel(request) }; requestTask = task
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    public func cancel() {
        let wasBusy = storedBusy
        requestTask?.cancel(); requestTask = nil; catalogTask?.cancel(); catalogTask = nil
        operation = UUID(); storedBusy = false; storedReview = nil
        if wasBusy { storedMessage = "Request cancelled. A response will not be saved; an already-sent request cannot be recalled." }
    }
    public func invalidate() { cancel(); invalidated = true; archive = nil; storedMessage = nil; storedCatalog = [] }

    func forgetReports() {
        guard readable, let saved = archive else { return }
        cancel()
        do {
            // Keep usage accounting and preferences when deleting reports; deletion cannot reset the limit.
            var cleared = saved; cleared.records = []
            archive = try store.update(cleared, expectedRevision: saved.revision)
            storedMessage = "Personal reports on this device were removed. Health imports and provider keys are unchanged."
        } catch { archive = nil; storedMessage = PersonalReportFailure.storage.localizedDescription }
    }

    public static func removeLocalData(for identity: PersonalHealthIdentity, snapshots: PrivateSnapshotStore? = nil) throws {
        try PersonalProviderKeychain(identity: identity).removeAll()
        try PersonalReportStore(snapshots: snapshots).remove(identity)
    }
    public static func eraseAllLocalData(identities: [PersonalHealthIdentity] = [], snapshots: PrivateSnapshotStore? = nil) throws {
        if let snapshots {
            for identity in identities { try removeLocalData(for: identity, snapshots: snapshots) }
        } else {
            try PersonalProviderKeychain.eraseAll()
            try PersonalReportStore.eraseAll()
        }
    }

    private func makeRequest(prompt: String, preferences: PersonalReportPreferences, diagnostic: Bool = false) throws -> ModelRequest {
        try preferences.validate()
        guard preferences.provider != .ollama || !preferences.localAddress.isEmpty else { throw PersonalReportFailure.invalid }
        let key = try keys.read(preferences.provider)
        guard !preferences.provider.needsKey || !key.isEmpty else { throw PodError.message("Save your own API key for this personal account first.") }
        return .init(provider: preferences.provider, model: preferences.model, key: key, localAddress: preferences.localAddress,
                     instructions: diagnostic ? "Follow the brief test request." : PersonalReportPrompt.instructions, prompt: prompt, diagnostic: diagnostic)
    }

    private func reserve() throws -> PersonalReportArchive {
        guard readable, requestPermitted(), var saved = archive else { throw PersonalReportFailure.changed }
        if saved.usageMonth != month { saved.usageMonth = month; saved.attempts = 0 }
        if saved.preferences.provider.needsKey {
            guard saved.attempts < saved.preferences.monthlyLimit else { throw PersonalReportFailure.limit }
            saved.attempts += 1
        }
        let next = try store.update(saved, expectedRevision: saved.revision); archive = next
        return next
    }

    private func checkReview(_ review: PersonalReportReview) throws {
        try Task.checkCancellation()
        guard readable, requestPermitted(), review == storedReview, review.expiresAt >= now(),
              review.archiveRevision == archive?.revision, review.preferences == archive?.preferences, !review.facts.isEmpty,
              review.health.map(evidenceCurrent) ?? true else { throw PersonalReportFailure.changed }
    }

    private func checkOperation(_ identifier: UUID, revision: UUID, health: PersonalReportEvidence?) throws {
        try Task.checkCancellation()
        guard readable, requestPermitted(), operation == identifier, archive?.revision == revision,
              health.map(evidenceCurrent) ?? true, try store.read(access.identity)?.revision == revision else {
            throw PersonalReportFailure.changed
        }
    }

    private func append(_ reply: ModelReply, review: PersonalReportReview, permission: PersonalReportPermission,
                        to archive: inout PersonalReportArchive) throws {
        if let previous = review.previous {
            guard let index = archive.records.firstIndex(of: previous) else { throw PersonalReportFailure.changed }
            archive.records[index].report.followUps = (previous.report.followUps ?? []) + [
                .init(id: UUID(), createdAt: now(), question: review.question, text: reply.text, provider: review.preferences.provider,
                      model: reply.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens)]
            archive.records[index].answerPermissions.append(permission)
        } else {
            let report = PersonalSleepReport(id: UUID(), createdAt: now(), provider: review.preferences.provider, model: reply.model,
                source: review.source, facts: review.facts, text: reply.text, inputTokens: reply.inputTokens,
                outputTokens: reply.outputTokens, comparison: review.comparison)
            archive.records = Array(([.init(report: report, permission: permission)] + archive.records).prefix(30))
        }
    }

    private func finish(_ error: Error, operation identifier: UUID) {
        guard readable, operation == identifier else { return }
        if error as? PersonalReportFailure == .changed { archive = nil; storedReview = nil }
        storedMessage = error is CancellationError ? "Request cancelled. No report was saved."
            : (error as? PersonalReportFailure)?.localizedDescription ?? (error as? PodError)?.localizedDescription
                ?? "The model request could not be completed. No automatic retry was made."
    }
}
