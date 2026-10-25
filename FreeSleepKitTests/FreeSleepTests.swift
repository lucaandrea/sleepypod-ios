import Testing
import Foundation
import HealthKit
@testable import FreeSleepKit

struct FreeSleepTests {
    @Test func validatesConnectionBoundary() throws {
        for address in ["http://localhost:3000", "http://192.168.1.10:3000", "http://pod.local:3000", "https://example.replit.app"] {
            #expect(throws: Never.self) { _ = try PodClient(address: address, token: "sample") }
        }
        for address in ["http://example.com", "https://user:password@example.com", "https://example.com?token=abc", "https://example.com/api", "file:///tmp/data"] {
            #expect(throws: (any Error).self) { _ = try PodClient(address: address, token: "") }
        }
    }
    @Test func missingAnalyticsRemainUnknown() throws {
        let data = Data(#"{"timeZone":"UTC","nights":[],"summary":{"recordedNights":0}}"#.utf8)
        let analytics = try JSONDecoder().decode(SleepAnalytics.self, from: data)
        #expect(analytics.summary.averageOccupiedMinutes == nil)
        #expect(SleepAnalytics.duration(nil) == "—")
        #expect(SleepAnalytics.duration(479.8) == "8h 0m")
    }
    @Test func healthPresenceMergesOverlapAndUsesInBedOnly() throws {
        let record = HealthExportRecords.Sleep(id: 1, present_intervals: [
            ["2026-10-13T22:00:00Z", "2026-10-13T23:00:00Z"],
            ["2026-10-13T22:30:00.000Z", "2026-10-14T00:00:00.000Z"],
            ["invalid", "2026-10-14T00:00:00Z"],
        ])
        let first = HealthSampleBuilder.presence([record], pod: "pod", side: .left, version: 1)
        let repeatExport = HealthSampleBuilder.presence([record], pod: "pod", side: .left, version: 2)
        let otherSide = HealthSampleBuilder.presence([record], pod: "pod", side: .right, version: 2)
        #expect(first.count == 1)
        let sample = try #require(first.first as? HKCategorySample)
        #expect(sample.value == HKCategoryValueSleepAnalysis.inBed.rawValue)
        #expect(sample.endDate.timeIntervalSince(sample.startDate) == 7200)
        #expect(sample.metadata?[HKMetadataKeySyncIdentifier] as? String == repeatExport[0].metadata?[HKMetadataKeySyncIdentifier] as? String)
        #expect(sample.metadata?[HKMetadataKeySyncIdentifier] as? String != otherSide[0].metadata?[HKMetadataKeySyncIdentifier] as? String)
        #expect(repeatExport[0].metadata?[HKMetadataKeySyncVersion] as? Int == 2)
    }
    @Test func healthHeartRateRejectsMissingAndOutOfRangeSamples() {
        let records = [Double?.none, 0, 60, 999].enumerated().map { index, value in
            HealthExportRecords.Vital(id: index, timestamp: "2026-10-13T23:00:00Z", heart_rate: value)
        }
        let samples = HealthSampleBuilder.heart(records, pod: "pod", side: .left, version: 1)
        #expect(samples.count == 1)
        #expect((samples.first as? HKQuantitySample)?.quantity.doubleValue(for: .count().unitDivided(by: .minute())) == 60)
    }
    @Test func editsToSchedulePreserveUnrelatedFields() throws {
        let initial = DailySchedule.empty
        var modified = initial
        modified.power.onTemperature = 76
        let decoded = try JSONDecoder().decode(DailySchedule.self, from: JSONEncoder().encode(modified))
        #expect(decoded.alarm == initial.alarm)
        #expect(decoded.temperatures == initial.temperatures)
        #expect(decoded.power.onTemperature == 76)
    }
}
