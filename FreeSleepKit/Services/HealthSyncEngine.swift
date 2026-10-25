import Foundation
import HealthKit

@MainActor
final class HealthSyncEngine {
    private let store: any HealthSampleStore
    private var running = false
    init(store: any HealthSampleStore) { self.store = store }

    // Fetch a complete export before changing Health. Save replacements before reconciling obsolete, owned samples.
    func synchronize(source: any HealthExportSource, settings: HealthSyncSettings, range: DateInterval, now: Date = .now) async throws -> Int {
        guard !running else { throw PodError.message("A Health sync is already running.") }
        running = true; defer { running = false }
        guard store.canWrite(heartRate: settings.exportHeartRate) else {
            throw PodError.message("Allow writing the selected data types in Apple Health before syncing.")
        }
        guard try await source.identity() == settings.podID else {
            throw PodError.message("This connection points to a different Pod. Save your personal Health setup again before syncing.")
        }
        async let presenceRequest = source.presence(side: settings.side, range: range)
        async let heartRequest = settings.exportHeartRate ? source.heartRate(side: settings.side, range: range) : []
        let (records, vitals) = try await (presenceRequest, heartRequest)
        try validate(records: records, vitals: vitals)
        guard try await source.identity() == settings.podID else { throw PodError.message("The Pod changed during export. Nothing was written to Health.") }
        try Task.checkCancellation()
        let old = try await store.existing(pod: settings.podID, side: settings.side, range: range, heartRate: settings.exportHeartRate)
        let previousVersion = old.compactMap { ($0.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue }.max() ?? 0
        guard previousVersion < Int.max else { throw PodError.message("A Health sample has an invalid sync version.") }
        let version = max(Int(now.timeIntervalSince1970 * 1000), previousVersion + 1)
        var identifiers: Set<String> = []
        var written = 0
        for offset in stride(from: 0, to: records.count, by: 100) {
            let batch = Array(records[offset..<min(offset + 100, records.count)])
            let samples = HealthSampleBuilder.presence(batch, pod: settings.podID, side: settings.side, version: version)
            written += try await save(samples, identifiers: &identifiers)
        }
        for offset in stride(from: 0, to: vitals.count, by: 400) {
            let batch = Array(vitals[offset..<min(offset + 400, vitals.count)])
            written += try await save(HealthSampleBuilder.heart(batch, pod: settings.podID, side: settings.side, version: version), identifiers: &identifiers)
        }
        try Task.checkCancellation()
        let obsolete = old.filter { sample in
            guard sample.metadata?["FreeSleepPod"] as? String == settings.podID,
                  sample.metadata?["FreeSleepSide"] as? String == settings.side.rawValue,
                  sample.endDate >= range.start, sample.startDate <= range.end,
                  sample.sampleType == HKCategoryType(.sleepAnalysis) || (settings.exportHeartRate && sample.sampleType == HKQuantityType(.heartRate)),
                  let identifier = sample.metadata?[HKMetadataKeySyncIdentifier] as? String else { return false }
            return !identifiers.contains(identifier)
        }
        for offset in stride(from: 0, to: obsolete.count, by: 400) {
            try Task.checkCancellation()
            try await store.delete(Array(obsolete[offset..<min(offset + 400, obsolete.count)]))
        }
        return written
    }

    private func save(_ samples: [HKSample], identifiers: inout Set<String>) async throws -> Int {
        for offset in stride(from: 0, to: samples.count, by: 400) {
            try Task.checkCancellation()
            let batch = Array(samples[offset..<min(offset + 400, samples.count)])
            try await store.save(batch)
            identifiers.formUnion(batch.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
            await Task.yield()
        }
        return samples.count
    }
    private func validate(records: [HealthExportRecords.Sleep], vitals: [HealthExportRecords.Vital]) throws {
        guard Set(records.map(\.id)).count == records.count, Set(vitals.map(\.id)).count == vitals.count else {
            throw PodError.message("The Pod returned duplicate export records. Retry the sync.")
        }
        for record in records {
            guard record.valid != false, record.present_intervals.allSatisfy({ interval in
                guard interval.count == 2, let start = HealthSampleBuilder.date(interval[0]), let end = HealthSampleBuilder.date(interval[1]) else { return false }
                return end > start
            }) else { throw PodError.message("Pod presence record \(record.id) is incomplete. Resolve the record before syncing to Health.") }
        }
        guard vitals.allSatisfy({ HealthSampleBuilder.date($0.timestamp) != nil }) else {
            throw PodError.message("The Pod returned an invalid heart-rate timestamp. Nothing was written to Health.")
        }
    }
}
