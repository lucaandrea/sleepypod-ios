import Foundation

struct BiometricReplayResources: Codable, Sendable {
    let version: String
    let scope: String
    let expectedProcesses: Int
    let measuredProcesses: Int
    let totalWallMs: Double?
    let totalCpuMs: Double?
    let largestProcessPeakRssBytes: Double?
    let ingestionHealthMeasured: Bool
    var supported: Bool {
        version == "waveform-resource-summary-v1" && scope == "sequential_python_processes_excluding_coordinator_and_scorer"
        && !ingestionHealthMeasured && (0...180).contains(expectedProcesses) && (0...expectedProcesses).contains(measuredProcesses)
        && [totalWallMs, totalCpuMs, largestProcessPeakRssBytes].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true }
    }
}
struct BiometricReplayOperations: Codable, Sendable {
    struct Memory: Codable, Sendable {
        let version: String
        let scope: String
        let attempts: Int
        let samples: Int
        let allSamplesAvailable: Bool
        let peakObservedRssBytes: Double?
        let maximumObservationGapMs: Double
        let intervalMs: Int
        let exactKernelPeak: Bool
        var supported: Bool {
            version == "process-group-rss-observations-v1" && scope == "sum_rss_of_replay_process_group" && intervalMs == 1000 && !exactKernelPeak
            && attempts >= 0 && samples >= 0 && samples <= attempts && maximumObservationGapMs >= 0
        }
    }
    struct Ingestion: Codable, Sendable {
        let source: String
        let checks: Int
        let samples: Int
        let allChecksMeasured: Bool
        let qualificationId: String?
        let maximumObservedAgeMs: Double?
        let maximumObservationGapMs: Double
        let nominalIntervalMs: Int
        let continuousMeasurement: Bool
        var supported: Bool {
            source == "supervisor_live_piezo_receipt_age" && nominalIntervalMs == 5000 && !continuousMeasurement
            && checks >= 0 && samples >= 0 && samples <= checks && maximumObservationGapMs >= 0
        }
    }
    let version: String
    let scope: String
    let wallMs: Double
    let memory: Memory?
    let ingestion: Ingestion
    var supported: Bool {
        version == "backtest-job-operations-v1" && scope == "admission_through_prepublication" && wallMs >= 0
        && ingestion.supported && (memory?.supported ?? true)
    }
}
