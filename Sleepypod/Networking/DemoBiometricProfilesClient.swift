import Foundation

/// In-memory configuration only. Demo never manufactures validation evidence or processor adoption.
actor DemoBiometricProfilesClient: BiometricProfilesServing {
    nonisolated let scope = "demo-biometric-profiles"
    private var revisions: [BiometricProfileRevision] = []
    private var events: [BiometricActivationEvent] = []
    private var bindings: [Side: BiometricProfileBinding] = [:]
    private var activationKeys: [String: BiometricActivationRequest] = [:]
    private var candidateKeys: [String: BiometricCandidateRequest] = [:]
    private var documents: (BiometricProfileManifest, BiometricProfileResolution)?
    func reviewValidated(_ request: BiometricValidatedReviewRequest) throws -> BiometricValidatedEligibility {
        _ = try request.query()
        throw APIError.serverError(message: "Demo uses synthetic examples. They cannot validate a profile for application.")
    }
    func activateValidated(_ request: BiometricValidatedRequest) throws -> BiometricActivationEvent {
        _ = try request.body()
        throw APIError.serverError(message: "Demo uses synthetic examples. They cannot validate a profile for application.")
    }
    func manifest() throws -> BiometricProfileManifest { try fixture().0 }
    private func fixture() throws -> (BiometricProfileManifest, BiometricProfileResolution) {
        if let documents { return documents }
        func read<Value: Decodable>(_ name: String, _: Value.Type) throws -> Value {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { throw APIError.serverError(message: "The bundled biometric demo is unavailable.") }
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        }
        let value = try (read("biometric-profile-manifest", BiometricProfileManifest.self), read("biometric-profile-defaults", BiometricProfileResolution.self))
        documents = value; return value
    }
    func overview(side: Side) throws -> BiometricProfileOverview {
        let (manifest, defaults) = try fixture(); let binding = binding(side)
        let selected = try binding.desiredRevisionId.map { try profile(id: $0) }
        let classifier = try manifest.stageDefaults()
        return .init(desired: .init(binding: binding, resolved: selected?.resolved ?? defaults.resolved, hash: selected?.resolvedHash ?? defaults.hash, isDefault: selected == nil, warning: nil),
                     stageView: .init(classifier: classifier, isDefault: true, provenance: .init(interpretation: "current_classifier_view", source: "demo", generation: nil, revisionId: nil, bundleHash: defaults.hash, stageHash: try hash(.encoded(classifier)), manifestHash: manifest.manifestHash, effectiveSampleTimeMs: nil, warning: nil)),
                     legacyStageView: .init(classifier: classifier, personalized: false, migrationPending: false), runtimeHealth: health, runtimeStatus: "unreported", receipts: [], sensorCalibration: [], activationAvailable: true,
                     limitations: ["Demo has no sensor calibration, processor acknowledgements or validation results."])
    }
    private var health: BiometricRuntimeHealth {
        .init(state: "unreported", staleAfterMs: 120000, components: ["heart_rate", "breathing_rate", "hrv_index"].map { .init(component: $0, generation: nil, state: "unreported", ageMs: nil) })
    }
    func activationStatus(side: Side, id: String?) throws -> BiometricActivationStatus {
        let current = binding(side)
        let event = events.first { $0.side == side && (id == nil ? $0.generation == current.generation : $0.id == id) }
        if id != nil && event == nil { throw APIError.serverError(message: "Activation request not found for this side.") }
        return .init(desiredGeneration: current.generation, isCurrent: event?.generation == current.generation, event: event, deliveryState: event == nil ? nil : "pending", observedState: event == nil ? "unreported" : "pending_delivery", receiptHealth: health, receipts: [])
    }
    func history(side: Side, beforeGeneration: Int?) -> BiometricActivationPage {
        let values = events.filter { $0.side == side && (beforeGeneration == nil || $0.generation < beforeGeneration!) }.sorted { $0.generation > $1.generation }
        let items = Array(values.prefix(50)); return .init(items: items, nextGeneration: values.count > 50 ? items.last?.generation : nil)
    }
    func profiles(side: Side, cursor: BiometricProfilePage.Cursor?) -> BiometricProfilePage {
        let values = revisions.filter { revision in
            guard revision.side == side else { return false }
            guard let cursor else { return true }
            return revision.createdAtMs < cursor.createdAtMs || revision.createdAtMs == cursor.createdAtMs && revision.id < cursor.id
        }.sorted { $0.createdAtMs == $1.createdAtMs ? $0.id > $1.id : $0.createdAtMs > $1.createdAtMs }
        let items = Array(values.prefix(100)); return .init(items: items, nextCursor: values.count > 100 ? items.last.map { .init(createdAtMs: $0.createdAtMs, id: $0.id) } : nil)
    }
    func profile(id: String) throws -> BiometricProfileRevision {
        guard let revision = revisions.first(where: { $0.id == id }) else { throw APIError.serverError(message: "Profile revision not found.") }; return revision
    }
    func resolve(overrides: [BiometricOverride], manifestHash: String) throws -> BiometricProfileResolution {
        let (manifest, defaults) = try fixture()
        guard manifestHash == manifest.manifestHash, overrides.count <= 64, Set(overrides.map(\.path)).count == overrides.count else { throw invalid }
        let parameters = try manifest.parameters()
        let allowedStage = Set(["rules", "lowSignalRules", "fallback", "lowSignalBelow", "smoothIsolatedEpochs", "transitions", "outliers.heartRate.min", "outliers.heartRate.max", "outliers.hrv.min", "outliers.hrv.max", "outliers.breathingRate.min", "outliers.breathingRate.max", "outliers.heartRateSpikeStdDevs"].map { "sleep_stages.ruleset.\($0)" } + ["sleep_stages.engine"])
        var config = defaults.resolved
        for item in overrides {
            if let parameter = parameters.first(where: { $0.path == item.path }) {
                guard let number = item.value.number, parameter.accepts(number) else { throw invalid }
            } else if !allowedStage.contains(item.path) { throw invalid }
            config = try config.replacing(at: item.path, with: item.value)
        }
        guard let stage = config["sleep_stages"] else { throw invalid }
        let classifier = try JSONDecoder().decode(RemoteStageClassifier.self, from: JSONEncoder().encode(stage))
        guard classifier.validation == nil else { throw invalid }
        return .init(resolved: config, hash: config == defaults.resolved ? defaults.hash : try hash(config), manifestHash: manifestHash, overrides: overrides.sorted { $0.path < $1.path }, provenance: Dictionary(uniqueKeysWithValues: overrides.map { ($0.path, "override") }))
    }
    func create(_ request: BiometricCandidateRequest) throws -> BiometricProfileRevision {
        if let prior = candidateKeys[request.idempotencyKey] {
            guard prior == request, let revision = revisions.first(where: { $0.idempotencyKey == request.idempotencyKey }) else { throw invalid }
            return revision
        }
        let manifest = try manifest(); let result = try resolve(overrides: request.overrides, manifestHash: request.baseManifestHash)
        let parent = try request.parentRevisionId.map { try profile(id: $0) }
        guard parent == nil || parent?.side == request.side else { throw invalid }
        let family = parent?.familyId ?? UUID().uuidString
        let revision = BiometricProfileRevision(id: UUID().uuidString, familyId: family, revision: (revisions.filter { $0.familyId == family }.map(\.revision).max() ?? 0) + 1, side: request.side, baseManifestHash: manifest.manifestHash, baseManifest: manifest.manifest, overrides: result.overrides, resolved: result.resolved, resolvedHash: result.hash, dependencyHashes: [:], parentRevisionId: request.parentRevisionId, origin: request.origin, requester: request.requester, idempotencyKey: request.idempotencyKey, requestHash: try hash(.encoded(request)), createdAtMs: (Date.now.timeIntervalSince1970 * 1000).rounded(.down))
        candidateKeys[request.idempotencyKey] = request; revisions.append(revision); return revision
    }
    func compare(side: Side, revisionId: String?, againstRevisionId: String?) throws -> BiometricProfileDiff {
        let defaults = try fixture().1
        func selected(_ id: String?) throws -> (JSONValue, String, [BiometricOverride]) {
            guard let id else { return (defaults.resolved, defaults.hash, []) }
            let revision = try profile(id: id); guard revision.side == side else { throw invalid }
            return (revision.resolved, revision.resolvedHash, revision.overrides)
        }
        let before = try selected(againstRevisionId), after = try selected(revisionId)
        let paths = Set(before.2.map(\.path) + after.2.map(\.path)).sorted()
        let changes = paths.compactMap { path -> BiometricProfileDiff.Change? in
            guard let old = before.0.value(at: path), let new = after.0.value(at: path), old != new else { return nil }
            return .init(path: path, before: old, after: new)
        }
        let intent = paths.filter { path in before.2.first { $0.path == path }?.value != after.2.first { $0.path == path }?.value }
        return .init(revisionId: revisionId, againstRevisionId: againstRevisionId, beforeHash: before.1, afterHash: after.1, changes: changes, intentChangedPaths: intent)
    }
    func compatibility(side: Side, id: String) throws -> BiometricProfileCompatibility {
        let revision = try profile(id: id); guard revision.side == side else { throw invalid }
        return .init(id: id, resolvedHash: revision.resolvedHash, compatible: true, evidence: "not_checked", limitations: ["Schema and engine compatibility do not establish improved biometric agreement."])
    }
    func activate(_ request: BiometricActivationRequest) throws -> BiometricActivationEvent {
        if let prior = activationKeys[request.idempotencyKey] {
            guard prior == request, let event = events.first(where: { $0.side == request.side && $0.generation == request.expectedGeneration + 1 }) else { throw invalid }; return event
        }
        let current = binding(request.side); let overview = try overview(side: request.side)
        guard current.generation == request.expectedGeneration, request.allowUnvalidated,
              request.action != .activate || request.revisionId != nil,
              request.action != .reset || request.revisionId == nil,
              request.action != .rollback || current.generation > 0 && request.revisionId == current.previousRevisionId else { throw invalid }
        let diff = try compare(side: request.side, revisionId: request.revisionId, againstRevisionId: current.desiredRevisionId)
        guard diff.afterHash == request.expectedResolvedHash else { throw invalid }
        let now = Date.now.timeIntervalSince1970 * 1000
        let event = BiometricActivationEvent(id: UUID().uuidString, side: request.side, generation: current.generation + 1, action: request.action.rawValue, previousRevisionId: current.desiredRevisionId, nextRevisionId: request.revisionId, previousHash: overview.desired.hash, nextHash: diff.afterHash, evaluationId: nil, evidence: .object(["status": .string("manual_unvalidated"), "demo": .bool(true)]), requester: request.requester, state: "pending_delivery", reason: nil, createdAtMs: now, updatedAtMs: now)
        bindings[request.side] = .init(side: request.side, generation: event.generation, desiredRevisionId: request.revisionId, previousRevisionId: current.desiredRevisionId, updatedAtMs: now)
        activationKeys[request.idempotencyKey] = request; events.append(event); return event
    }
    private func binding(_ side: Side) -> BiometricProfileBinding { bindings[side] ?? .init(side: side, generation: 0, desiredRevisionId: nil, previousRevisionId: nil, updatedAtMs: 0) }
    private func hash(_ value: JSONValue) throws -> String {
        try BiometricDemoCanonicalJSON.hash(value)
    }
    private var invalid: APIError { .serverError(message: "The profile request is incompatible or its reviewed binding changed.") }
}
