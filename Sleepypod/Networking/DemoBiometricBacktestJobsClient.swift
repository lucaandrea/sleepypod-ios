import Foundation

extension DemoBiometricDatasetsClient {
    func evaluationOverview(side: Side) async throws -> BiometricProfileOverview { try await evaluationProfileClient.overview(side: side) }
    func evaluationProfiles(side: Side, cursor: BiometricProfilePage.Cursor?) async throws -> BiometricProfilePage { try await evaluationProfileClient.profiles(side: side, cursor: cursor) }
    func evaluationProfile(id: String) async throws -> BiometricProfileRevision { try await evaluationProfileClient.profile(id: id) }
    func jobs(side: Side, cursor: BiometricBacktestPage.Cursor?) async throws -> BiometricBacktestPage {
        let ordered = savedJobs.values.filter { jobSides[$0.id] == side }.sorted {
            $0.createdAtMs == $1.createdAtMs ? $0.id > $1.id : $0.createdAtMs > $1.createdAtMs
        }.filter { item in cursor.map { item.createdAtMs < $0.createdAtMs || (item.createdAtMs == $0.createdAtMs && item.id < $0.id) } ?? true }
        let items = Array(ordered.prefix(50))
        return .init(items: items, nextCursor: ordered.count > 50 ? items.last.map { .init(createdAtMs: $0.createdAtMs, id: $0.id) } : nil)
    }
    func job(id: String) async throws -> BiometricBacktestJob {
        guard let saved = savedJobs[id] else { throw BiometricBacktestInput.error("This synthetic job is unavailable.") }; return saved
    }
    func submit(_ request: BiometricBacktestSubmission) async throws -> BiometricBacktestJob {
        _ = try request.validated()
        if let result = try existingJob(request) { return result }
        let selected = try await experiment(id: request.experimentId), inputs = try await dataset(id: selected.datasetId)
        let candidate = try await evaluationProfile(id: request.candidateRevisionId), defaults = try await evaluationProfileClient.manifest()
        let overview = try await evaluationOverview(side: selected.side)
        if let result = try existingJob(request) { return result }
        guard inputs.available, selected.side == candidate.side, overview.desired.binding.generation == request.expectedBindingGeneration,
              inputs.manifest.splitProtocol.assignments.contains(where: { $0.split == request.split.rawValue }), savedJobs.count < 1000 else {
            throw BiometricBacktestInput.error("Review a retained dataset, candidate and current baseline before queueing.")
        }
        // Recheck retention after awaited profile reads; Demo records a request but runs no worker.
        guard try retainedDataset(id: inputs.id).available else { throw BiometricBacktestInput.error("These synthetic inputs were released.") }
        guard let defaultConfiguration = defaults.manifest["defaults"] else { throw BiometricBacktestInput.error("The synthetic default configuration is unavailable.") }
        let defaultsHash = try BiometricDemoCanonicalJSON.hash(defaultConfiguration)
        let now = (Date.now.timeIntervalSince1970 * 1000).rounded(.down)
        let result = BiometricBacktestJob(id: UUID().uuidString.lowercased(), experimentId: selected.id, state: .queued, attempt: 0,
            progress: .init(phase: "Demo request only · no worker runs", completedNights: 0, totalNights: inputs.manifest.splitProtocol.assignments.filter { $0.split == request.split.rawValue }.count),
            cancellationRequestedAtMs: nil, error: nil, createdAtMs: now, updatedAtMs: now, datasetId: inputs.id, datasetHash: inputs.contentHash,
            evaluatorBuildHash: try BiometricDemoCanonicalJSON.hash(JSONValue.string("synthetic-queue-only-no-evaluator")), split: request.split,
            configurations: [.init(label: "default", revisionId: nil, hash: defaultsHash), .init(label: "current", revisionId: nil, hash: defaultsHash), .init(label: "candidate", revisionId: candidate.id, hash: candidate.resolvedHash)],
            evaluationScope: selected.protocol.backtestScope)
        jobRequests[request.idempotencyKey] = request; jobRequestIds[request.idempotencyKey] = result.id
        savedJobs[result.id] = result; jobSides[result.id] = selected.side
        if request.split == .holdout {
            savedExperiments[selected.id] = .init(id: selected.id, datasetId: selected.datasetId, side: selected.side, protocol: selected.protocol,
                protocolHash: selected.protocolHash, holdoutAccesses: (savedExperiments[selected.id]?.holdoutAccesses ?? selected.holdoutAccesses) + 1, createdAtMs: selected.createdAtMs)
        }
        return result
    }
    private func existingJob(_ request: BiometricBacktestSubmission) throws -> BiometricBacktestJob? {
        guard let previous = jobRequests[request.idempotencyKey] else { return nil }
        guard previous == request, let identity = jobRequestIds[request.idempotencyKey], let result = savedJobs[identity] else { throw BiometricBacktestInput.error("This retry identity belongs to another evaluation request.") }
        return result
    }
    func cancelJob(id: String) async throws -> BiometricBacktestJob {
        let current = try await job(id: id)
        if current.state.terminal { return current }
        let now = (Date.now.timeIntervalSince1970 * 1000).rounded(.down)
        let result = BiometricBacktestJob(id: current.id, experimentId: current.experimentId,
            state: current.state == .queued || current.state == .interrupted ? .cancelled : .cancellationRequested,
            attempt: current.attempt, progress: current.progress, cancellationRequestedAtMs: current.cancellationRequestedAtMs ?? now,
            error: current.error, createdAtMs: current.createdAtMs, updatedAtMs: now, datasetId: current.datasetId, datasetHash: current.datasetHash,
            evaluatorBuildHash: current.evaluatorBuildHash, split: current.split, configurations: current.configurations, evaluationScope: current.evaluationScope)
        savedJobs[id] = result; return result
    }
}
