import Foundation
import Observation

/// Parse independent score projections once per read; preserve prior results on network failure.
@MainActor @Observable final class BiometricReportWorkspace {
    let job: BiometricBacktestJob
    let side: Side
    let client: any BiometricReportsServing
    private(set) var descriptor: BiometricReportDescriptor?
    private(set) var report: BiometricEvaluationReport?
    private(set) var validatedSelection: BiometricValidatedSelection?
    private(set) var numeric: BiometricNumericReport?
    private(set) var stages: BiometricStageReport?
    private(set) var numericError: String?
    private(set) var stageError: String?
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?
    private var generation = 0
    init(job: BiometricBacktestJob, side: Side, client: any BiometricReportsServing) { self.job = job; self.side = side; self.client = client }
    func load() async {
        generation += 1; let reading = generation; loading = true
        defer { if generation == reading { loading = false } }
        do {
            let result = try await client.summary(id: job.id)
            guard !Task.isCancelled, reading == generation else { return }
            if let result { try result.validate(job: job) }
            var header: BiometricEvaluationReport?
            if let result, result.available {
                header = try result.decoded(BiometricEvaluationReport.self)
                try header?.validate(job: job, side: side, projection: result.projection)
            }
            validatedSelection = result.flatMap { try? BiometricValidatedSelection(side: side, job: job, descriptor: $0) }
            descriptor = result; report = header; numeric = nil; stages = nil; numericError = nil; stageError = nil
            if let result, let header {
                do { let rows = try result.decoded(BiometricNumericReport.self); try rows.validate(job: job); numeric = rows }
                catch { numericError = "Numerical details are unavailable or incompatible." }
                if header.hasStages {
                    do { let rows = try result.decoded(BiometricStageReport.self); try rows.validate(job: job); stages = rows }
                    catch { stageError = "Stage details are unavailable or incompatible." }
                }
            }
            loaded = true; error = nil
        } catch { if !Task.isCancelled, reading == generation { self.error = error.localizedDescription } }
    }
    /// A confirmed release removes cached details immediately and supersedes older polls.
    func acceptRelease(_ receipt: BiometricReportReleaseReceipt) {
        guard let descriptor, receipt.confirms(id: job.id, hash: descriptor.contentHash) else { return }
        generation += 1; loading = false; report = nil; validatedSelection = nil; numeric = nil; stages = nil; numericError = nil; stageError = nil; error = nil
        self.descriptor = .init(jobId: descriptor.jobId, fencingToken: descriptor.fencingToken, report: nil, contentHash: descriptor.contentHash,
                                completedAtMs: descriptor.completedAtMs, releasedAtMs: receipt.releasedAtMs, available: false,
                                currentHoldoutUseCount: descriptor.currentHoldoutUseCount, projection: descriptor.projection, contentHashScope: descriptor.contentHashScope)
    }
}
