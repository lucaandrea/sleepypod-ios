import Foundation

struct BiometricObservationExample: Decodable, Sendable {
    let run: BiometricObservationRun
    let prepared: BiometricObservationPrepared
    let reference: ReferenceImportInput
    let report: BiometricObservationReport
    let comparison: BiometricObservationReport
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "biometric-observation-example", withExtension: "json") else { throw BiometricBacktestInput.error("The bundled observation example is unavailable.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
/// Demo retains scheduling intent; it never attaches precomputed observations to a newly selected candidate.
actor DemoBiometricObservationsClient: BiometricObservationsServing {
    nonisolated let scope = "demo-biometric-observations"
    nonisolated let profilesClient: any BiometricProfilesServing
    private let profiles: DemoBiometricProfilesClient
    private var example: BiometricObservationExample?
    private var prepared: [String: BiometricObservationPrepared] = [:]
    private var runs: [String: BiometricObservationRun] = [:]
    private var requests: [String: (input: BiometricObservationSubmission, id: String)] = [:]
    init(profiles: DemoBiometricProfilesClient) { self.profiles = profiles; profilesClient = profiles }
    private func fixture() throws -> BiometricObservationExample { if let example { return example }; let value = try BiometricObservationExample.load(); example = value; return value }
    func templates() -> BiometricObservationTemplates { .init(items: [.init(id: "demo-plan-only", label: "Demo scheduling · no live worker", maximumWindowMs: 600000)]) }
    private func bindings() async throws -> JSONValue {
        var result: [String: JSONValue] = [:]
        for side in Side.allCases {
            let current = try await profiles.overview(side: side)
            result[side.rawValue] = .object(["generation": .number(Double(current.desired.binding.generation + 1)), "resolvedHash": .string(current.desired.hash)])
        }
        return .object(result)
    }
    func prepare(_ input: BiometricObservationPreparation) async throws -> BiometricObservationPrepared {
        try input.validate(maximumWindowMs: 600000)
        guard input.templateId == "demo-plan-only" else { throw BiometricBacktestInput.error("Reload the demo observation template.") }
        let expected = try await bindings(), manifest = try await profiles.manifest()
        let candidateHash: String
        if let revisionId = input.candidateRevisionId {
            let revision = try await profiles.profile(id: revisionId)
            guard revision.side == input.side else { throw BiometricBacktestInput.error("The selected candidate belongs to another side.") }
            candidateHash = revision.resolvedHash
        } else { candidateHash = try await profiles.resolve(overrides: [], manifestHash: manifest.manifestHash).hash }
        var plan = try fixture().prepared.plan
        let changes: [String: JSONValue] = ["side": .string(input.side.rawValue), "subjectId": .string(input.subjectId), "startMs": .number(input.startMs), "endMs": .number(input.endMs),
            "candidateRevisionId": input.candidateRevisionId.map(JSONValue.string) ?? .null, "candidateConfigHash": .string(candidateHash),
            "activeConfigHash": expected[input.side.rawValue]!["resolvedHash"]!, "expectedBindings": expected,
            "execution.configHashes.left": expected["left"]!["resolvedHash"]!, "execution.configHashes.right": expected["right"]!["resolvedHash"]!,
            "execution.budgets.wallMs": .number(602000)]
        for (path, value) in changes { plan = try plan.replacing(at: path, with: value) }
        plan = try plan.replacing(at: "execution.configHashes.\(input.side.rawValue)", with: .string(candidateHash))
        let value = BiometricObservationPrepared(status: "prepared_not_admitted", plan: plan, planHash: try BiometricDemoCanonicalJSON.hash(plan))
        try value.validate(for: input)
        if prepared.count >= 100 { prepared.removeAll() }
        prepared[value.planHash] = value; return value
    }
    func create(_ input: BiometricObservationSubmission) async throws -> BiometricObservationRun {
        _ = try input.body()
        if let previous = requests[input.idempotencyKey] {
            guard previous.input == input else { throw BiometricBacktestInput.error("The scheduling identity was reused with another plan.") }
            return try get(id: previous.id)
        }
        let currentBindings = try await bindings()
        // An overlapping retry may have committed while the shared profile actor was read.
        if let previous = requests[input.idempotencyKey] {
            guard previous.input == input else { throw BiometricBacktestInput.error("The scheduling identity was reused with another plan.") }
            return try get(id: previous.id)
        }
        let plan = input.prepared.plan
        guard runs.count < 20, prepared[input.prepared.planHash] == input.prepared,
              let side = input.side, let start = plan["startMs"]?.number, let end = plan["endMs"]?.number,
              start > Date.now.timeIntervalSince1970 * 1000, plan["expectedBindings"] == currentBindings else {
            throw BiometricBacktestInput.error("Prepare the future demo plan again after checking the profile and run limit.")
        }
        let run = BiometricObservationRun(id: UUID().uuidString, side: side, subjectId: plan["subjectId"]!.string!, state: .pending,
            planHash: input.prepared.planHash, candidateConfigHash: plan["candidateConfigHash"]!.string!, activeConfigHash: plan["activeConfigHash"]!.string!,
            candidateRevisionId: plan["candidateRevisionId"]?.string, candidateIdentitySaved: true, startMs: start, endMs: end,
            createdAtMs: (Date.now.timeIntervalSince1970 * 1000).rounded(), endedAtMs: nil, heartbeatAtMs: nil, reason: "demo_scheduling_only_no_worker", pointCount: 0, byteCount: 0, workerReceiptAvailable: false)
        runs[run.id] = run; requests[input.idempotencyKey] = (input, run.id); return run
    }
    func list(side: Side, afterId: String?) throws -> BiometricObservationPage {
        let example = try fixture()
        for id in Array(runs.keys) { _ = try get(id: id) }
        let values = (Array(runs.values) + (side == .left ? [example.run] : [])).filter { $0.side == side && (afterId == nil || $0.id > afterId!) }.sorted { $0.id < $1.id }
        let items = Array(values.prefix(20)); return .init(items: items, nextCursor: values.count > 20 ? items.last?.id : nil)
    }
    func get(id: String) throws -> BiometricObservationRun {
        let example = try fixture(); if example.run.id == id { return example.run }
        guard let run = runs[id] else { throw BiometricBacktestInput.error("Observation not found in this demo session.") }
        // Demo has no worker; a reached execution window must not look like active processing.
        if run.state.isActive, run.startMs <= Date.now.timeIntervalSince1970 * 1000 {
            guard case .object(var fields) = try JSONValue.encoded(run) else { throw BiometricBacktestInput.error("Invalid demo observation.") }
            fields["state"] = .string("failed")
            fields["endedAtMs"] = .number((Date.now.timeIntervalSince1970 * 1000).rounded())
            fields["reason"] = .string("demo_scheduling_only_no_worker")
            let expired = try JSONDecoder().decode(BiometricObservationRun.self, from: JSONEncoder().encode(JSONValue.object(fields)))
            runs[id] = expired; return expired
        }
        return run
    }
    func stop(id: String) throws -> BiometricObservationStop {
        let current = try get(id: id)
        guard current.state.isActive else { return .init(run: current, localAttemptSettled: false) }
        var value = try JSONValue.encoded(current)
        value = try value.replacing(at: "state", with: .string("stopped"))
        // JSONEncoder omits optional fields; rebuild this nullable field without losing the other descriptor values.
        guard case .object(var fields) = value else { throw BiometricBacktestInput.error("Invalid demo observation.") }
        fields["endedAtMs"] = .number((Date.now.timeIntervalSince1970 * 1000).rounded())
        let stopped = try JSONDecoder().decode(BiometricObservationRun.self, from: JSONEncoder().encode(JSONValue.object(fields)))
        runs[id] = stopped; return .init(run: stopped, localAttemptSettled: false)
    }
    func report(id: String) throws -> BiometricObservationReport {
        let example = try fixture(); if id == example.run.id { return example.report }
        let run = try get(id: id)
        guard case .object(var fields) = try JSONValue.encoded(example.report) else { throw BiometricBacktestInput.error("Invalid synthetic report.") }
        fields["runId"] = .string(id); fields["planHash"] = .string(run.planHash); fields["capturedAtMs"] = .number((Date.now.timeIntervalSince1970 * 1000).rounded())
        fields["state"] = .string(run.state.rawValue); fields["reason"] = .string("demo_scheduling_only_no_worker")
        fields["health"] = .string("issues_detected"); fields["issues"] = .array([.string("simulated_demo"), .string("no_observations")])
        for key in ["expectedSlots", "observedSamples", "maximumGapMs", "attemptsObserved"] { fields[key] = .number(0) }
        fields["metrics"] = .array([]); fields["pairing"] = .object(["activeOnly": .number(0), "candidateOnly": .number(0), "unknownInputIdentity": .number(0)])
        fields["snapshotHash"] = .string(try BiometricDemoCanonicalJSON.hash(run)); fields["executionPolicyHash"] = .null
        fields["workerReceipt"] = .null; fields["referenceSummary"] = .null; fields["excludedBoundaryReferences"] = .number(0)
        fields["reportHash"] = nil
        fields["limitations"] = .array([.string("Demo scheduling has no live worker. No observations or qualification evidence are generated for this request.")])
        fields["reportHash"] = .string(try BiometricDemoCanonicalJSON.hash(JSONValue.object(fields)))
        return try JSONDecoder().decode(BiometricObservationReport.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }
    func compare(_ input: BiometricObservationReference) throws -> BiometricObservationReport {
        _ = try input.body(); let example = try fixture()
        guard input.run.id == example.run.id, input.input == example.reference else {
            throw BiometricBacktestInput.error("This demo includes only the bundled synthetic reference comparison. Use a connected controller to compare other records.")
        }
        return example.comparison
    }
}
