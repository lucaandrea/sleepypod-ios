import Foundation

protocol BiometricReportsServing: Sendable {
    func summary(id: String) async throws -> BiometricReportDescriptor?
    func release(id: String, expectedHash: String) async throws -> BiometricReportReleaseReceipt?
    func stages(_ selection: BiometricTraceSelection) async throws -> BiometricStageTracePage
    func numeric(_ selection: BiometricTraceSelection) async throws -> BiometricNumericTracePage
    func references(_ selection: BiometricTraceSelection, metric: BiometricReferenceTraceMetric) async throws -> BiometricReferenceTracePage
}

struct CoreBiometricReportsClient: BiometricReportsServing {
    let transport: CoreRESTClient
    func summary(id: String) async throws -> BiometricReportDescriptor? {
        try await transport.get("\(root(id))/summary")
    }
    func release(id: String, expectedHash: String) async throws -> BiometricReportReleaseReceipt? {
        guard BiometricBacktestInput.isHash(expectedHash) else { throw BiometricBacktestInput.error("Review the exact retained report before releasing it.") }
        struct Request: Encodable, Sendable { let expectedContentHash: String }
        return try await transport.post("\(root(id))/result/release", body: Request(expectedContentHash: expectedHash), returning: BiometricReportReleaseReceipt?.self)
    }
    func stages(_ selection: BiometricTraceSelection) async throws -> BiometricStageTracePage {
        try await transport.get("\(root(selection.jobId))/trace", query: selection.query())
    }
    func numeric(_ selection: BiometricTraceSelection) async throws -> BiometricNumericTracePage {
        try await transport.get("\(root(selection.jobId))/numeric-trace", query: selection.query())
    }
    func references(_ selection: BiometricTraceSelection, metric: BiometricReferenceTraceMetric) async throws -> BiometricReferenceTracePage {
        var query = try selection.query(includeConfiguration: false); query["metric"] = metric.rawValue
        return try await transport.get("\(root(selection.jobId))/reference-trace", query: query)
    }
    private func root(_ id: String) throws -> String { "biometric-tuning/backtests/\(try BiometricBacktestInput.identifier(id))" }
}
