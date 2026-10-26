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
    private var retained: [String: BiometricDataset] = [:]
    private var requests: [String: BiometricDatasetRequest] = [:]
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
    func dataset(id: String) async throws -> BiometricDataset {
        guard let value = retained[id] else { throw BiometricBacktestInput.error("This synthetic dataset is unavailable.") }; return value
    }
    func create(_ request: BiometricDatasetRequest) async throws -> BiometricDataset {
        _ = try request.validated()
        if let previous = requests[request.idempotencyKey] {
            guard previous == request, let id = requestIds[request.idempotencyKey], let value = retained[id] else { throw BiometricBacktestInput.error("This retry identity belongs to another selection.") }
            return value
        }
        guard let snapshot = try BiometricDatasetDemoFixture.load(side: request.side).snapshots.first(where: { $0.selection == request.selection }) else {
            throw BiometricBacktestInput.error("Demo supports the bundled synthetic sessions and demo-sleeper identifier. Connect to a controller for your own datasets.")
        }
        let fixture = snapshot.descriptor
        let result = BiometricDataset(id: UUID().uuidString.lowercased(), side: fixture.side, subjectId: fixture.subjectId, contentHash: fixture.contentHash,
                                      manifest: fixture.manifest, byteLength: fixture.byteLength, createdAtMs: Date.now.timeIntervalSince1970 * 1000, releasedAtMs: nil, available: true)
        requests[request.idempotencyKey] = request; requestIds[request.idempotencyKey] = result.id; retained[result.id] = result
        return result
    }
    func release(id: String) async throws -> BiometricDataset {
        let current = try await dataset(id: id)
        guard current.available else { return current }
        guard let fixture = try BiometricDatasetDemoFixture.load(side: current.side).snapshots.first(where: { $0.descriptor.contentHash == current.contentHash }) else { throw BiometricBacktestInput.error("The synthetic dataset identity is unavailable.") }
        let result = BiometricDataset(id: current.id, side: current.side, subjectId: current.subjectId, contentHash: current.contentHash,
                                      manifest: current.manifest, byteLength: fixture.releasedByteLength, createdAtMs: current.createdAtMs,
                                      releasedAtMs: Date.now.timeIntervalSince1970 * 1000, available: false)
        retained[id] = result; return result
    }
}
