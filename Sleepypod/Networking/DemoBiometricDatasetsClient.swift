import Foundation

struct BiometricDatasetDemoFixture: Decodable, Sendable {
    struct Snapshot: Decodable, Sendable { let selection: BiometricDatasetSelection; let descriptor: BiometricDataset; let releasedByteLength: Int }
    let side: Side
    let sessions: ReplaySessionPage
    let capabilities: [ReplaySessionCapabilities]
    let references: ReferenceLibraryPage
    let snapshots: [Snapshot]
    static func load(side: Side) throws -> Self {
        guard let url = Bundle.main.url(forResource: "dataset-demo", withExtension: "json"),
              let fixture = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url)).first(where: { $0.side == side }) else {
            throw BiometricBacktestInput.error("The synthetic dataset examples are unavailable.")
        }
        return fixture
    }
}

/// Demo copies literal Core-generated synthetic manifests; it never claims a real evaluation ran.
actor DemoBiometricDatasetsClient: BiometricDatasetsServing {
    nonisolated let scope = "demo-biometric-datasets"
    let evaluationProfileClient: any BiometricProfilesServing
    var savedJobs: [String: BiometricBacktestJob] = [:]
    var jobSides: [String: Side] = [:]
    var jobRequests: [String: BiometricBacktestSubmission] = [:]
    var jobRequestIds: [String: String] = [:]
    init(profiles: any BiometricProfilesServing = DemoBiometricProfilesClient()) { evaluationProfileClient = profiles }
    var savedExperiments: [String: BiometricExperiment] = [:]
    var experimentRequests: [String: BiometricExperimentRequest] = [:]
    var experimentRequestIds: [String: String] = [:]
    private var retained: [String: BiometricDataset] = [:]
    private var requests: [String: BiometricDatasetRequest] = [:]
    private var waveformRequests: [String: WaveformDatasetRequest] = [:]
    private var requestIds: [String: String] = [:]
    func sessions(side: Side, cursor: ReplaySessionPage.Cursor?) async throws -> ReplaySessionPage {
        cursor == nil ? try BiometricDatasetDemoFixture.load(side: side).sessions : .init(items: [], nextCursor: nil)
    }
    func capabilities(side: Side, id: Int) async throws -> ReplaySessionCapabilities {
        guard let value = try BiometricDatasetDemoFixture.load(side: side).capabilities.first(where: { $0.session.id == id }) else { throw BiometricBacktestInput.error("The synthetic session is unavailable.") }
        return value
    }
    func references(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage {
        cursor == nil ? try BiometricDatasetDemoFixture.load(side: side).references : .init(items: [], nextCursor: nil)
    }
    func datasets(side: Side, cursor: BiometricDatasetPage.Cursor?) async throws -> BiometricDatasetPage {
        .init(items: cursor == nil ? retained.values.filter { $0.side == side }.sorted { $0.createdAtMs > $1.createdAtMs } : [], nextCursor: nil)
    }
    func dataset(id: String) async throws -> BiometricDataset { try retainedDataset(id: id) }
    func retainedDataset(id: String) throws -> BiometricDataset {
        guard let value = retained[id] else { throw BiometricBacktestInput.error("This synthetic dataset is unavailable.") }; return value
    }
    func create(_ request: BiometricDatasetRequest) async throws -> BiometricDataset {
        _ = try request.validated()
        guard waveformRequests[request.idempotencyKey] == nil else { throw WaveformInput.failure("This key already belongs to a waveform selection.") }
        if let previous = requests[request.idempotencyKey] {
            guard previous == request, let id = requestIds[request.idempotencyKey], let value = retained[id] else { throw BiometricBacktestInput.error("This retry identity belongs to another selection.") }
            return value
        }
        guard let snapshot = try BiometricDatasetDemoFixture.load(side: request.side).snapshots.first(where: { $0.selection == request.selection }) else {
            throw BiometricBacktestInput.error("Demo supports the bundled synthetic sessions and demo-sleeper identifier. Connect to a controller for your own datasets.")
        }
        let fixture = snapshot.descriptor
        guard retained[fixture.id] == nil else { throw WaveformInput.failure("This bundled synthetic selection is already saved. Inspect it in Retained datasets or restart Demo for a fresh session.") }
        let result = BiometricDataset(id: fixture.id, side: fixture.side, subjectId: fixture.subjectId, contentHash: fixture.contentHash,
                                      manifest: fixture.manifest, byteLength: fixture.byteLength, createdAtMs: Date.now.timeIntervalSince1970 * 1000, releasedAtMs: nil, available: true)
        requests[request.idempotencyKey] = request; requestIds[request.idempotencyKey] = result.id; retained[result.id] = result
        return result
    }
    func release(id: String) async throws -> BiometricDataset {
        let current = try await dataset(id: id)
        guard current.available else { return current }
        guard !savedJobs.values.contains(where: { $0.datasetId == id && !$0.state.terminal }) else { throw BiometricBacktestInput.error("Cancel or finish active evaluations before releasing their retained inputs.") }
        let processedBytes = try BiometricDatasetDemoFixture.load(side: current.side).snapshots.first { $0.descriptor.contentHash == current.contentHash }?.releasedByteLength
        let waveformBytes = try BiometricWaveformDemoFixture.load().first { $0.descriptor.contentHash == current.contentHash }?.releasedByteLength
        guard let releasedBytes = processedBytes ?? waveformBytes else { throw BiometricBacktestInput.error("The synthetic dataset identity is unavailable.") }
        let result = BiometricDataset(id: current.id, side: current.side, subjectId: current.subjectId, contentHash: current.contentHash,
                                      manifest: current.manifest, byteLength: releasedBytes, createdAtMs: current.createdAtMs,
                                      releasedAtMs: Date.now.timeIntervalSince1970 * 1000, available: false)
        retained[id] = result; return result
    }
    func replayAdmission() async throws -> ReplayAdmission {
        .init(configured: true, qualificationId: "synthetic-admission-example", admitted: true, reasons: [])
    }
    func rawSources(startMs: Double, endMs: Double, cursor: String?) async throws -> InspectedRawPage {
        let items = try BiometricWaveformDemoFixture.sources().filter { source in
            guard let first = source.inspection.inventory.firstEventMs, let last = source.inspection.inventory.lastEventMs else { return false }
            return first < endMs && last >= startMs && (cursor.map { source.id > $0 } ?? true)
        }
        return .init(items: items, nextCursor: nil)
    }
    func inspectRaw(afterName: String?) async throws -> RawInspectionResult {
        let sources = try BiometricWaveformDemoFixture.sources().sorted { $0.inspection.sourceName < $1.inspection.sourceName }
        guard let next = sources.first(where: { source in afterName.map { source.inspection.sourceName > $0 } ?? true }) else { return .init(status: .complete, nextCursor: nil, source: nil) }
        return .init(status: .inspected, nextCursor: next.inspection.sourceName, source: next)
    }
    func createWaveform(_ request: WaveformDatasetRequest) async throws -> WaveformDatasetResponse {
        _ = try request.validated()
        guard requests[request.idempotencyKey] == nil else { throw WaveformInput.failure("This key already belongs to a processed selection.") }
        if let previous = waveformRequests[request.idempotencyKey] {
            guard previous == request, let id = requestIds[request.idempotencyKey], let value = retained[id] else { throw WaveformInput.failure("This retry identity belongs to another waveform selection.") }
            return .init(status: .published, dataset: value)
        }
        guard let parent = retained[request.parentDatasetId], parent.available, parent.contentHash == request.expectedContentHash,
              let fixture = try BiometricWaveformDemoFixture.load().first(where: { $0.parentId == parent.id }),
              fixture.request.cohorts == request.cohorts else { throw WaveformInput.failure("Select the bundled archives for every night in this retained synthetic parent.") }
        guard retained[fixture.descriptor.id] == nil else { throw WaveformInput.failure("This synthetic waveform selection is already saved. Inspect it in Retained datasets.") }
        waveformRequests[request.idempotencyKey] = request; requestIds[request.idempotencyKey] = fixture.descriptor.id
        retained[fixture.descriptor.id] = fixture.descriptor
        return .init(status: .published, dataset: fixture.descriptor)
    }
}

/// Keep synthetic candidates and inputs alive while navigating between profile and backtest screens.
struct BiometricDemoSession {
    let profiles: DemoBiometricProfilesClient
    let datasets: DemoBiometricDatasetsClient
    init() { let profiles = DemoBiometricProfilesClient(); self.profiles = profiles; datasets = .init(profiles: profiles) }
}
