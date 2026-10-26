import Foundation

extension CoreBiometricDatasetsClient {
    func replayAdmission() async throws -> ReplayAdmission {
        try await transport.get("biometric-tuning/replay-admission")
    }
    func rawSources(startMs: Double, endMs: Double, cursor: String?) async throws -> InspectedRawPage {
        guard endMs > startMs, cursor.map(BiometricBacktestInput.isHash) ?? true else { throw WaveformInput.failure("Invalid archive window or cursor.") }
        var query = ["startMs": try BiometricBacktestInput.milliseconds(startMs), "endMs": try BiometricBacktestInput.milliseconds(endMs)]
        if let cursor { query["afterId"] = cursor }
        return try await transport.get("biometric-tuning/raw-sources", query: query)
    }
    func inspectRaw(afterName: String?) async throws -> RawInspectionResult {
        guard afterName.map(WaveformInput.validSourceName) ?? true else { throw WaveformInput.failure("Invalid archive scan cursor.") }
        return try await transport.post("biometric-tuning/raw-sources/inspect", body: RawInspectionRequest(afterName: afterName), returning: RawInspectionResult.self)
    }
    func createWaveform(_ request: WaveformDatasetRequest) async throws -> WaveformDatasetResponse {
        try await transport.post("biometric-tuning/waveform-datasets", body: request.validated(), returning: WaveformDatasetResponse.self)
    }
}
