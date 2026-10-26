import Foundation
import Observation

@MainActor @Observable final class WaveformDatasetDraft {
    let parent: BiometricDataset
    private(set) var selected: [String: [String: InspectedRawSource]] = [:]
    init(parent: BiometricDataset) { self.parent = parent }
    var complete: Bool {
        parent.available && parent.manifest.supported && parent.manifest.version == "processed-dataset-manifest-v1"
            && !parent.manifest.splitProtocol.assignments.isEmpty
            && parent.manifest.splitProtocol.assignments.allSatisfy { !(selected[$0.cohortId] ?? [:]).isEmpty }
    }
    func toggle(_ source: InspectedRawSource, cohort: BiometricDatasetManifest.Cohort) throws {
        guard parent.manifest.splitProtocol.assignments.contains(cohort) else { throw WaveformInput.failure("The selected night is not in this frozen dataset.") }
        if selected[cohort.cohortId]?[source.id] != nil { selected[cohort.cohortId]?[source.id] = nil; return }
        guard source.selectable, (selected[cohort.cohortId]?.count ?? 0) < 64,
              let first = source.inspection.inventory.firstEventMs, let last = source.inspection.inventory.lastEventMs,
              first < cohort.endMs, last >= max(0, cohort.startMs - 300000) else { throw WaveformInput.failure("This archive cannot be selected for this night, or the 64-archive limit was reached.") }
        selected[cohort.cohortId, default: [:]][source.id] = source
    }
    func clear(_ cohortId: String) { selected[cohortId] = [:] }
    func request(key: String = UUID().uuidString.lowercased()) throws -> WaveformDatasetRequest {
        guard complete else { throw WaveformInput.failure("Select inspected archives for every frozen night.") }
        return try WaveformDatasetRequest(parentDatasetId: parent.id, expectedContentHash: parent.contentHash,
            cohorts: parent.manifest.splitProtocol.assignments.map { .init(cohortId: $0.cohortId, sourceIds: (selected[$0.cohortId] ?? [:]).keys.sorted()) }, idempotencyKey: key).validated()
    }
}
