import Foundation

extension DemoBiometricDatasetsClient {
    func experiments(side: Side, cursor: BiometricExperimentPage.Cursor?) async throws -> BiometricExperimentPage {
        let ordered = savedExperiments.values.filter { $0.side == side }.sorted {
            $0.createdAtMs == $1.createdAtMs ? $0.id > $1.id : $0.createdAtMs > $1.createdAtMs
        }.filter { item in cursor.map { item.createdAtMs < $0.createdAtMs || (item.createdAtMs == $0.createdAtMs && item.id < $0.id) } ?? true }
        let items = Array(ordered.prefix(50))
        return .init(items: items, nextCursor: ordered.count > 50 ? items.last.map { .init(createdAtMs: $0.createdAtMs, id: $0.id) } : nil)
    }
    func experiment(id: String) async throws -> BiometricExperiment {
        guard let saved = savedExperiments[id] else { throw BiometricBacktestInput.error("This synthetic experiment is unavailable.") }
        return saved
    }
    func create(_ request: BiometricExperimentRequest) async throws -> BiometricExperiment {
        _ = try request.validated()
        if let existing = experimentRequests[request.idempotencyKey] {
            guard existing == request, let identity = experimentRequestIds[request.idempotencyKey], let saved = savedExperiments[identity] else {
                throw BiometricBacktestInput.error("This experiment retry identity belongs to a different protocol.")
            }
            return saved
        }
        let parent = try await dataset(id: request.datasetId)
        try request.protocol.validateEditorProtocol(for: parent)
        guard savedExperiments.count < 1000 else { throw BiometricBacktestInput.error("The synthetic experiment library is full.") }
        let saved = BiometricExperiment(id: UUID().uuidString.lowercased(), datasetId: parent.id, side: parent.side,
            protocol: request.protocol, protocolHash: try BiometricDemoCanonicalJSON.hash(request.protocol), holdoutAccesses: 0,
            createdAtMs: (Date.now.timeIntervalSince1970 * 1000).rounded(.down))
        experimentRequests[request.idempotencyKey] = request; experimentRequestIds[request.idempotencyKey] = saved.id
        savedExperiments[saved.id] = saved
        return saved
    }
}
