import Foundation
import Observation

struct BiometricProfileReview: Sendable {
    let action: BiometricProfileAction
    let target: String?
    let binding: BiometricProfileBinding
    let beforeHash: String
    let afterHash: String
    let diff: BiometricProfileDiff?
    let recoveryWarning: String?
    func matches(_ overview: BiometricProfileOverview) -> Bool {
        overview.desired.binding == binding && overview.desired.hash == beforeHash
    }
}

@MainActor @Observable final class BiometricProfilesWorkspace {
    let side: Side
    let client: any BiometricProfilesServing
    private let pendingStore: BiometricProfilePendingStore
    private(set) var overview: BiometricProfileOverview?
    private(set) var observedAt: Date?
    private(set) var overviewError: String?
    private(set) var refreshing = false
    private(set) var activation: BiometricActivationStatus?
    private(set) var activationError: String?
    private(set) var event: BiometricActivationEvent?
    private(set) var profiles: BiometricProfilePage?
    private(set) var profileCursor: BiometricProfilePage.Cursor?
    private(set) var profilesError: String?
    private(set) var loadingProfiles = false
    private(set) var history: BiometricActivationPage?
    private(set) var historyCursor: Int?
    private(set) var historyError: String?
    private(set) var loadingHistory = false
    private(set) var pending: BiometricProfilePending?
    private(set) var validatedReview: BiometricValidatedReview?
    private(set) var review: BiometricProfileReview?
    private(set) var busy = false
    private(set) var mutationError: String?
    private(set) var notice: String?
    private(set) var savedCandidate: BiometricProfileRevision?
    private var pendingReadFailed = false

    init(side: Side, client: any BiometricProfilesServing, pendingStore: BiometricProfilePendingStore) {
        self.side = side; self.client = client; self.pendingStore = pendingStore
        do { pending = try pendingStore.read(scope: client.scope, side: side) }
        catch { mutationError = "Cannot read the retained request. \(error.localizedDescription)"; pendingReadFailed = true }
    }
    func isFresh(at now: Date = .now) -> Bool {
        guard overviewError == nil, let observedAt else { return false }
        return (0...15).contains(now.timeIntervalSince(observedAt))
    }
    var hasUnresolvedRequest: Bool { pending != nil || pendingReadFailed }
    var canStartMutation: Bool { !busy && pending == nil && !pendingReadFailed }
    var canApplyReview: Bool { canStartMutation && isFresh() && overview?.activationAvailable == true && review.map { item in overview.map(item.matches) ?? false } == true }

    var canApplyValidated: Bool {
        canStartMutation && !refreshing && isFresh() && overview?.activationAvailable == true && overview?.desired.warning == nil
            && validatedReview.map { item in overview.map { item.matches($0) } ?? false } == true
    }

    /// A failed observation preserves the last report but removes its current-health claim.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let value = try await client.overview(side: side)
            guard !Task.isCancelled else { return }
            guard value.desired.binding.side == side else { throw APIError.serverError(message: "The controller returned another side’s profile.") }
            overview = value; observedAt = .now; overviewError = nil
            if let validatedReview, !validatedReview.matches(value), pending == nil {
                self.validatedReview = nil; notice = "The profile or evidence review changed. Review again before applying."
            }
            if let review, !review.matches(value), pending == nil { self.review = nil; notice = "The saved profile changed. Compare again before applying a change." }
        } catch { if !Task.isCancelled { overviewError = error.localizedDescription } }
        await refreshActivation()
    }
    func refreshActivation(id: String? = nil) async {
        do {
            let value = try await client.activationStatus(side: side, id: id)
            guard !Task.isCancelled else { return }
            activation = value; activationError = nil
        } catch { if !Task.isCancelled { activationError = error.localizedDescription } }
    }
    func loadProfiles(cursor: BiometricProfilePage.Cursor? = nil) async {
        guard !loadingProfiles else { return }
        loadingProfiles = true; defer { loadingProfiles = false }
        do {
            let page = try await client.profiles(side: side, cursor: cursor)
            guard !Task.isCancelled else { return }
            guard page.items.allSatisfy({ $0.side == side }) else { throw APIError.serverError(message: "The controller returned profiles for another side.") }
            profiles = page; profileCursor = cursor; profilesError = nil
        } catch { if !Task.isCancelled { profilesError = error.localizedDescription } }
    }
    func loadHistory(beforeGeneration: Int? = nil) async {
        guard !loadingHistory else { return }
        loadingHistory = true; defer { loadingHistory = false }
        do {
            let page = try await client.history(side: side, beforeGeneration: beforeGeneration)
            guard !Task.isCancelled else { return }
            guard page.items.allSatisfy({ $0.side == side }) else { throw APIError.serverError(message: "The controller returned history for another side.") }
            history = page; historyCursor = beforeGeneration; historyError = nil
        } catch { if !Task.isCancelled { historyError = error.localizedDescription } }
    }
    func compare(action: BiometricProfileAction, target: String?) async {
        guard canStartMutation else { return }
        busy = true; review = nil; validatedReview = nil; mutationError = nil; notice = nil
        defer { busy = false }
        do {
            let current = try await client.overview(side: side)
            guard current.desired.binding.side == side, current.activationAvailable else { throw APIError.serverError(message: "Profile application is unavailable for this side.") }
            let binding = current.desired.binding
            let selection = action == .reset ? nil : action == .rollback ? binding.previousRevisionId : target
            guard action != .activate || selection != nil, action != .rollback || binding.generation > 0 else { throw APIError.serverError(message: "There is no profile to select for this action.") }
            let comparison: BiometricProfileDiff?
            if let warning = current.desired.warning {
                guard action == .reset else { throw APIError.serverError(message: warning) }
                comparison = nil
            } else {
                comparison = try await client.compare(side: side, revisionId: selection, againstRevisionId: binding.desiredRevisionId)
                guard comparison?.beforeHash == current.desired.hash, comparison?.revisionId == selection, comparison?.againstRevisionId == binding.desiredRevisionId else { throw APIError.serverError(message: "The comparison does not match the selected profile. Reload and compare again.") }
            }
            let latest = try await client.overview(side: side)
            guard latest.desired.binding == binding, latest.desired.hash == current.desired.hash else { throw APIError.serverError(message: "The saved profile changed during comparison. Compare again.") }
            try Task.checkCancellation()
            overview = latest; observedAt = .now; overviewError = nil
            review = .init(action: action, target: selection, binding: binding, beforeHash: current.desired.hash, afterHash: comparison?.afterHash ?? current.desired.hash, diff: comparison, recoveryWarning: current.desired.warning)
        } catch { if !Task.isCancelled { mutationError = error.localizedDescription } }
    }
    func applyReviewed(boundary: BiometricProfileBoundary) async {
        guard canApplyReview, let review else { mutationError = "Reload and compare the current profile before applying it."; return }
        let request = BiometricActivationRequest(action: review.action, side: side, revisionId: review.target, expectedGeneration: review.binding.generation, expectedResolvedHash: review.afterHash, boundary: boundary, requester: "ios-calibration", idempotencyKey: UUID().uuidString, allowUnvalidated: true)
        await retainAndSend(.activation(request))
    }
    /// Inspect the exact candidate and current binding before asking Core to verify retained evidence.
    func prepareValidated(_ selection: BiometricValidatedSelection) async {
        guard canStartMutation, selection.side == side else { return }
        busy = true; validatedReview = nil; review = nil; mutationError = nil; notice = nil
        defer { busy = false }
        do {
            try selection.validate()
            let current = try await client.overview(side: side)
            guard current.desired.binding.side == side, current.activationAvailable, current.desired.warning == nil else {
                throw BiometricBacktestInput.error("Resolve the current profile and processor configuration before reviewing application.")
            }
            let request = BiometricValidatedReviewRequest(selection: selection, expectedGeneration: current.desired.binding.generation)
            let eligibility = try await client.reviewValidated(request)
            guard eligibility.eligible else { throw BiometricBacktestInput.error("Core has not approved this candidate and evaluation for application.") }
            let comparison = try await client.compare(side: side, revisionId: selection.revisionId, againstRevisionId: current.desired.binding.desiredRevisionId)
            guard comparison.beforeHash == current.desired.hash, comparison.afterHash == selection.expectedResolvedHash,
                  comparison.revisionId == selection.revisionId, comparison.againstRevisionId == current.desired.binding.desiredRevisionId else {
                throw BiometricBacktestInput.error("The current profile comparison no longer matches this evaluated candidate.")
            }
            let latest = try await client.overview(side: side)
            guard latest.desired.binding == current.desired.binding, latest.desired.hash == current.desired.hash,
                  latest.activationAvailable, latest.desired.warning == nil else {
                throw BiometricBacktestInput.error("The saved profile changed during evidence review. Review again.")
            }
            try Task.checkCancellation()
            overview = latest; observedAt = .now; overviewError = nil
            validatedReview = .init(request: request, binding: latest.desired.binding, beforeHash: latest.desired.hash, diff: comparison, reviewedAt: .now)
        } catch { if !Task.isCancelled { mutationError = error.localizedDescription } }
    }
    func applyValidated(boundary: BiometricProfileBoundary) async {
        guard canApplyValidated, let validatedReview else {
            mutationError = "Refresh the exact evaluation and current profile before applying this revision."
            return
        }
        let request = BiometricValidatedRequest(review: validatedReview.request, boundary: boundary, requester: "ios-calibration", idempotencyKey: UUID().uuidString)
        await retainAndSend(.validated(request))
    }
    func saveCandidate(_ request: BiometricCandidateRequest, expectedHash: String) async -> Bool {
        guard canStartMutation, request.side == side else { return false }
        savedCandidate = nil
        await retainAndSend(.candidate(request, expectedHash: expectedHash))
        return savedCandidate != nil && pending == nil
    }
    func retryExactRequest() async {
        guard !busy, let pending, !pendingReadFailed else { return }
        await send(pending)
    }
    /// Forgetting a retry does not roll back a change that the controller may already have saved.
    func stopRetrying() async {
        guard !busy else { return }
        do {
            if let pending { try pendingStore.remove(pending, scope: client.scope, side: side) }
            else if pendingReadFailed { try pendingStore.discardUnreadable(scope: client.scope, side: side) }
            pending = nil; pendingReadFailed = false; review = nil; validatedReview = nil; mutationError = nil
            notice = "Retained retry removed. This does not undo a controller change. Inspect the latest profile and history before another action."
            await refresh(); await loadProfiles(); await loadHistory()
        } catch { mutationError = error.localizedDescription }
    }
    private func retainAndSend(_ request: BiometricProfilePending) async {
        do {
            try pendingStore.write(request, scope: client.scope, side: side)
            pending = request
        } catch { mutationError = "The request could not be retained, so it was not sent. \(error.localizedDescription)"; return }
        await send(request)
    }
    private func send(_ request: BiometricProfilePending) async {
        busy = true; mutationError = nil; notice = nil
        defer { busy = false }
        do {
            guard try pendingStore.read(scope: client.scope, side: side) == request else {
                throw APIError.serverError(message: "The retained request changed in another workspace. Reopen calibration before continuing.")
            }
            switch request {
            case .candidate(let input, let expectedHash):
                let result = try await client.create(input)
                guard result.side == side, result.idempotencyKey == input.idempotencyKey, result.resolvedHash == expectedHash, result.baseManifestHash == input.baseManifestHash else { throw APIError.serverError(message: "The candidate receipt did not match the retained request.") }
                savedCandidate = result
                notice = "Candidate saved without applying. Agreement with reference measurements has not been evaluated."
            case .validated(let input):
                let result = try await client.activateValidated(input)
                guard input.confirms(result) else { throw BiometricBacktestInput.error("The evaluated activation receipt did not match the retained request.") }
                event = result
                notice = "Evaluated activation request saved. Processor acknowledgement is reported separately."
            case .activation(let input):
                let result = try await client.activate(input)
                guard result.side == side, result.action == input.action.rawValue, result.nextRevisionId == input.revisionId, result.generation == input.expectedGeneration + 1, result.nextHash == input.expectedResolvedHash else { throw APIError.serverError(message: "The activation receipt did not match the retained request.") }
                event = result
                notice = "Activation request saved. Processor acknowledgement is reported separately."
            }
            try pendingStore.remove(request, scope: client.scope, side: side)
            pending = nil; review = nil; validatedReview = nil
            await refresh(); await loadProfiles(); await loadHistory()
        } catch {
            mutationError = "The complete result is not confirmed. The exact request is retained; retrying it reuses the same request identity. \(error.localizedDescription)"
        }
    }
}
