import Foundation
import Observation

@MainActor @Observable final class BiometricCandidateWorkspace {
    private(set) var manifest: BiometricProfileManifest?
    private(set) var parameters: [BiometricProfileManifest.Parameter] = []
    private(set) var parent: BiometricProfileRevision?
    private(set) var stage: RemoteStageRuleset?
    private(set) var stagePaths: Set<String> = []
    private(set) var numeric: [String: Double] = [:]
    private(set) var otherOverrides: [BiometricOverride] = []
    private(set) var resolution: BiometricProfileResolution?
    private(set) var request: BiometricCandidateRequest?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var reviewing = false
    private(set) var saved: BiometricProfileRevision?
    private var generation = 0
    private var initialOverrides: [BiometricOverride] = []
    let profile: BiometricProfilesWorkspace
    let selectedParentID: String?
    init(profile: BiometricProfilesWorkspace, parentID: String?) { self.profile = profile; selectedParentID = parentID }

    func load() async {
        guard manifest == nil, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let manifest = try await profile.client.manifest()
            let overview = try await profile.client.overview(side: profile.side)
            guard overview.desired.binding.side == profile.side else { throw incompatible }
            if selectedParentID == nil, overview.desired.warning != nil { throw incompatible }
            let parentID = selectedParentID ?? overview.desired.binding.desiredRevisionId
            let parent: BiometricProfileRevision?
            if let parentID { parent = try await profile.client.profile(id: parentID) } else { parent = nil }
            if let parent, parent.side != profile.side || parent.baseManifestHash != manifest.manifestHash { throw incompatible }
            let parameters = try manifest.parameters()
            var classifier = try JSONValue.encoded(manifest.stageDefaults())
            let overrides = parent?.overrides ?? []
            for item in overrides where item.path.hasPrefix("sleep_stages.") {
                classifier = try classifier.replacing(at: String(item.path.dropFirst("sleep_stages.".count)), with: item.value)
            }
            let decoded = try JSONDecoder().decode(RemoteStageClassifier.self, from: JSONEncoder().encode(classifier))
            guard decoded.validation == nil else { throw incompatible }
            try Task.checkCancellation()
            self.manifest = manifest; self.parameters = parameters; self.parent = parent; stage = decoded.ruleset
            initialOverrides = overrides.sorted { $0.path < $1.path }
            let numericPaths = Set(parameters.map(\.path))
            numeric = try Dictionary(uniqueKeysWithValues: overrides.filter { numericPaths.contains($0.path) }.map { item in
                guard let number = item.value.number else { throw incompatible }
                return (item.path, number)
            })
            stagePaths = Set(overrides.filter { $0.path.hasPrefix("sleep_stages.ruleset.") }.map(\.path))
            otherOverrides = overrides.filter { !numericPaths.contains($0.path) && !$0.path.hasPrefix("sleep_stages.ruleset.") }
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    var validation: String? {
        guard manifest != nil, let stage else { return "Load the parameter definitions first." }
        for parameter in parameters {
            if let value = numeric[parameter.path], !parameter.accepts(value) { return "\(parameter.title) must be \(parameter.type == "integer" ? "a whole number " : "")between \(parameter.minimum.formatted()) and \(parameter.maximum.formatted())." }
        }
        return stage.validation
    }
    var editable: Bool { !loading && !reviewing && profile.canStartMutation }
    var dirty: Bool { (try? overrides()) != initialOverrides }
    func number(_ path: String) -> Double { numeric[path] ?? parameters.first { $0.path == path }?.defaultValue ?? .nan }
    func original(_ parameter: BiometricProfileManifest.Parameter) -> Double { initialOverrides.first { $0.path == parameter.path }?.value.number ?? parameter.defaultValue }
    func setNumber(_ path: String, value: Double?) { guard editable else { return }; numeric[path] = value; changed() }
    func setStage(_ next: RemoteStageRuleset, path: String) { guard editable else { return }; stage = next; stagePaths.insert("sleep_stages.ruleset.\(path)"); changed() }
    func removeStageOverride(_ path: String) {
        guard editable, let manifest, let stage else { return }
        do {
            let defaults = try JSONValue.encoded(manifest.stageDefaults().ruleset)
            guard let value = defaults.value(at: path) else { throw incompatible }
            let updated = try JSONValue.encoded(stage).replacing(at: path, with: value)
            self.stage = try JSONDecoder().decode(RemoteStageRuleset.self, from: JSONEncoder().encode(updated))
            stagePaths.remove("sleep_stages.ruleset.\(path)"); changed()
        } catch { self.error = error.localizedDescription }
    }
    func review() async {
        guard editable, let manifest, validation == nil else { return }
        reviewing = true; resolution = nil; request = nil; error = nil; saved = nil
        let revision = generation; defer { reviewing = false }
        do {
            let result = try await profile.client.resolve(overrides: overrides(), manifestHash: manifest.manifestHash)
            guard revision == generation, !Task.isCancelled else { return }
            guard result.manifestHash == manifest.manifestHash, result.overrides.count <= 64 else { throw incompatible }
            resolution = result
            request = BiometricCandidateRequest(side: profile.side, parentRevisionId: parent?.id, baseManifestHash: manifest.manifestHash, overrides: result.overrides, origin: "manual", requester: "ios-calibration", idempotencyKey: UUID().uuidString)
        } catch { if revision == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func save() async {
        guard let request, let resolution, editable else { return }
        if await profile.saveCandidate(request, expectedHash: resolution.hash) {
            saved = profile.savedCandidate; self.request = nil; self.resolution = nil
        }
    }
    func overrides() throws -> [BiometricOverride] {
        guard let stage, validation == nil else { throw APIError.serverError(message: validation ?? "Missing stage rules") }
        let encoded = try JSONValue.encoded(stage)
        var result = otherOverrides + numeric.map { .init(path: $0.key, value: .number($0.value)) }
        for path in stagePaths {
            guard let value = encoded.value(at: String(path.dropFirst("sleep_stages.ruleset.".count))) else { throw incompatible }
            result.append(.init(path: path, value: value))
        }
        guard result.count <= 64 else { throw APIError.serverError(message: "A profile can contain at most 64 explicit overrides.") }
        return result.sorted { $0.path < $1.path }
    }
    private func changed() { generation += 1; resolution = nil; request = nil; saved = nil; error = nil }
    private var incompatible: APIError { .serverError(message: "The saved profile or parameter definitions are incompatible with this editor.") }
}
