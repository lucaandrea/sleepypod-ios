import Foundation
import HealthKit
import FreeSleepKit

/// Reads local Health data only; other people, apps' predicted stages and unmeasured gaps are not training labels.
@MainActor
enum NightAnomalyHealthReader {
    static func read(health: HealthSyncService, calendar: Calendar, now: Date) async throws -> NightAnomalyDataset.Audit {
        let context = health.watchReferenceContext
        let start = calendar.date(byAdding: .day, value: -180, to: now) ?? now
        let raw = try await health.analysisSleepSamples(start: start, end: now)
        let samples = raw.filter { sample in
            let bundle = sample.sourceRevision.source.bundleIdentifier.lowercased()
            let own = Bundle.main.bundleIdentifier?.lowercased() ?? "com.lucaandrea.freesleep"
            return !bundle.hasPrefix(own) && !bundle.contains("sleepypod") && sample.device?.name?.localizedCaseInsensitiveContains("sleepypod") != true
        }.map { sample in
            NightAnomalyDataset.Sample(id: sample.uuid.uuidString, sourceID: sourceID(sample), sourceName: sourceName(sample),
                                       start: sample.startDate, end: sample.endDate, category: sample.value)
        }
        var audit = NightAnomalyDataset.build(samples, calendar: calendar, now: now)
        let watchSources = Set(raw.filter { StageComparison.isAppleWatchSleep(StageComparison.HealthSource($0)) }.map(sourceID))
        // Non-Watch source cohorts retain sleep/timing features only; daily averages are not overnight measurements.
        let watchNights = audit.nights.filter { watchSources.contains($0.sourceID) }
        if health.preferences.readVitals, let first = watchNights.map(\.start).min(), let last = watchNights.map(\.end).max() {
            var readings: [String: [HKQuantitySample]] = [:]
            for (feature, type) in [("heartRate", HKQuantityTypeIdentifier.heartRate), ("hrvSDNN", .heartRateVariabilitySDNN), ("respiratoryRate", .respiratoryRate)] {
                readings[feature] = try await health.analysisQuantitySamples(type, start: first, end: last)
            }
            audit.nights = audit.nights.map { night in
                guard watchSources.contains(night.sourceID) else { return night }
                var values = night.values, evidence = [night.evidenceDigest]
                for (feature, rawSamples) in readings {
                    let samples = Dictionary(rawSamples.filter {
                        sourceID($0) == night.sourceID && $0.startDate >= night.start && $0.endDate <= night.end
                    }.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.startDate < $1.startDate }
                    // Require readings spread across the night, not one isolated daytime-style aggregate.
                    guard samples.count >= (feature == "hrvSDNN" ? 3 : 12), let first = samples.first, let last = samples.last,
                          first.startDate.timeIntervalSince(night.start) <= 2 * 3600,
                          night.end.timeIntervalSince(last.endDate) <= 2 * 3600,
                          zip(samples, samples.dropFirst()).allSatisfy({ $1.startDate.timeIntervalSince($0.endDate) <= 2 * 3600 }) else { continue }
                    let unit: HKUnit = feature == "hrvSDNN" ? .secondUnit(with: .milli) : .count().unitDivided(by: .minute())
                    let measurements = samples.map { $0.quantity.doubleValue(for: unit) }.sorted()
                    guard measurements.allSatisfy(\.isFinite) else { continue }
                    let middle = measurements.count / 2
                    values[feature] = measurements.count.isMultiple(of: 2) ? (measurements[middle - 1] + measurements[middle]) / 2 : measurements[middle]
                    evidence += samples.map { "\(feature)|\($0.uuid)|\($0.startDate.timeIntervalSince1970)|\($0.endDate.timeIntervalSince1970)|\($0.quantity.doubleValue(for: unit))" }
                }
                return .init(id: night.id, sourceID: night.sourceID, sourceName: night.sourceName, start: night.start, end: night.end,
                             values: values, coverage: night.coverage, maximumGapMinutes: night.maximumGapMinutes,
                             sampleCount: night.sampleCount, evidenceDigest: NightAnomalyDataset.digest(evidence.sorted().joined(separator: "\n")))
            }
        }
        guard context == health.watchReferenceContext, !PersonalWorkspaceBoundary.isActive else { throw CancellationError() }
        try Task.checkCancellation()
        return audit
    }

    private static func sourceID(_ sample: HKSample) -> String {
        // Product type separates Watch generations. A local identifier, when supplied, separates same-model devices.
        NightAnomalyDataset.digest([sample.sourceRevision.source.bundleIdentifier, sample.sourceRevision.productType ?? "unknown",
                                    sample.device?.localIdentifier ?? "", sample.device?.model ?? ""].joined(separator: "|"))
    }

    private static func sourceName(_ sample: HKSample) -> String {
        [sample.sourceRevision.source.name, sample.sourceRevision.productType ?? sample.device?.model].compactMap { $0 }.joined(separator: " · ")
    }
}
