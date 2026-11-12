import Foundation
import Testing
@testable import FreeSleepKit

struct DaytimeContextTests {
    private let bedtime = Date(timeIntervalSince1970: 1_793_600_000)
    private let watch = DaytimeContext.Source(identifier: "watch.example", name: "Example Watch", device: "Watch")
    private let phone = DaytimeContext.Source(identifier: "phone.example", name: "Example Phone", device: "Phone")
    private func observation(_ kind: DaytimeContext.Kind = .workout, start: Double = -7200, end: Double = -3600,
                             value: Double = 30, source: DaytimeContext.Source? = nil) -> DaytimeContext.Observation {
        .init(id: UUID(), kind: kind, source: source ?? watch, start: bedtime.addingTimeInterval(start),
              end: bedtime.addingTimeInterval(end), value: value, workoutActivity: kind == .workout ? 37 : nil)
    }
    private func snapshot(_ observations: [DaytimeContext.Observation] = []) -> DaytimeContext {
        .init(importedAt: bedtime.addingTimeInterval(86_400), timeZone: "America/Los_Angeles",
              reads: DaytimeContext.Kind.allCases.map {
                  .init(kind: $0, state: .completed, start: bedtime.addingTimeInterval(-90 * 86_400), end: bedtime.addingTimeInterval(86_400))
              }, observations: observations)
    }
    private func summary(_ snapshot: DaytimeContext) throws -> DaytimeContextSummary {
        try .make(snapshot: snapshot, bedtime: bedtime, now: bedtime.addingTimeInterval(86_400))
    }

    @Test func successfulEmptyReadIsUnknownActivityRatherThanZero() throws {
        let result = try summary(snapshot())
        #expect(result.groups.isEmpty)
        #expect(Set(result.emptyKinds) == Set([.workout, .exerciseMinutes, .activeEnergyKilocalories, .steps]))
        #expect(result.previousWrist.isEmpty)
    }
    @Test func explicitZeroSampleRemainsDifferentFromNoSample() throws {
        let result = try summary(snapshot([observation(.steps, value: 0)]))
        #expect(result.groups.first?.total == 0)
        #expect(!result.emptyKinds.contains(.steps))
    }
    @Test func sourcesAreNotAddedTogether() throws {
        let result = try summary(snapshot([observation(.steps, value: 300, source: watch), observation(.steps, value: 250, source: phone)]))
        #expect(result.groups.count == 2)
        #expect(Set(result.groups.compactMap(\.total)) == Set([250, 300]))
    }
    @Test func sameModelDevicesRemainSeparateFromEachOtherAndUnidentifiedRecords() throws {
        var firstWatch = watch; firstWatch.deviceIdentifier = "local-watch-one"
        var secondWatch = watch; secondWatch.deviceIdentifier = "local-watch-two"
        let records = [observation(.steps, value: 300, source: firstWatch),
                       observation(.steps, value: 250, source: secondWatch),
                       observation(.steps, value: 100, source: watch)]
        let result = try summary(snapshot(records))
        #expect(result.groups.count == 3)
        #expect(Set(result.groups.compactMap(\.total)) == Set([100, 250, 300]))
        #expect(result.groups.allSatisfy { $0.excludedOverlaps == 0 })
        #expect(try result == summary(snapshot(Array(records.reversed()))))
    }
    @Test func invalidDeviceIdentityIsRejected() {
        var value = snapshot([observation()])
        value.observations[0].source.deviceIdentifier = ""
        #expect(throws: DaytimeContextError.self) { try value.validate() }
    }
    @Test func exactDuplicatesCountOnlyOnce() throws {
        let workout = observation()
        let result = try summary(snapshot([workout, workout]))
        #expect(result.groups.first?.observationCount == 1)
        #expect(result.groups.first?.total == 30)
    }
    @Test func conflictingDuplicateRejectsTheSnapshot() {
        let workout = observation()
        var changed = workout; changed.value = 45
        #expect(throws: DaytimeContextError.self) { try snapshot([workout, changed]).validate() }
    }
    @Test func overlappingComponentIsExcludedWithoutDroppingAdjacentSamples() throws {
        let records = [observation(.steps, start: -10_000, end: -5000, value: 100),
                       observation(.steps, start: -9000, end: -8000, value: 200),
                       observation(.steps, start: -7000, end: -4000, value: 300),
                       observation(.steps, start: -4000, end: -3000, value: 40)]
        let result = try summary(snapshot(records)).groups.first
        #expect(result?.excludedOverlaps == 3)
        #expect(result?.observationCount == 1)
        #expect(result?.total == 40)
    }
    @Test func allOverlapsYieldNoInventedZeroTotal() throws {
        let result = try summary(snapshot([observation(), observation()])).groups.first
        #expect(result?.excludedOverlaps == 2)
        #expect(result?.total == nil)
    }
    @Test func workoutAndActivityAreDistinctMeasures() throws {
        let result = try summary(snapshot([observation(), observation(.exerciseMinutes, value: 20)]))
        #expect(result.groups.count == 2)
        #expect(result.groups.first { $0.kind == .workout }?.total == 30)
        #expect(result.groups.first { $0.kind == .exerciseMinutes }?.total == 20)
    }
    @Test func currentNightWristAndPostBedtimeActivityCannotLeakIntoPriorContext() throws {
        let records = [observation(.sleepingWristCelsius, start: -86_400, end: -57_600, value: 34.2),
                       observation(.sleepingWristCelsius, start: 0, end: 28_800, value: 35.8),
                       observation(.steps, start: 100, end: 500, value: 200)]
        let result = try summary(snapshot(records))
        #expect(result.previousWrist.count == 1)
        #expect(result.previousWrist.first?.absoluteCelsius == 34.2)
        #expect(result.groups.isEmpty)
    }
    @Test func wristRetainsAbsoluteUnitsAndOriginalInterval() throws {
        let wrist = observation(.sleepingWristCelsius, start: -86_400, end: -57_600, value: 34.2)
        let result = try summary(snapshot([wrist])).previousWrist.first
        #expect(result?.start == wrist.start)
        #expect(result?.end == wrist.end)
        #expect(result?.source == watch)
        #expect(result?.absoluteCelsius == 34.2)
    }
    @Test func staleWristAndUnfinishedIntervalsAreExcluded() throws {
        let records = [observation(.sleepingWristCelsius, start: -8 * 86_400, end: -7 * 86_400, value: 34.2),
                       observation(.workout, start: -300, end: 300, value: 5)]
        let result = try summary(snapshot(records))
        #expect(result.previousWrist.isEmpty)
        #expect(result.groups.isEmpty)
    }
    @Test func unavailableOrPartialWindowsDoNotAppearAsCompleteActivity() throws {
        var value = snapshot([observation(.steps, value: 200)])
        value.reads[value.reads.firstIndex { $0.kind == .workout }!].state = .unavailable
        value.reads[value.reads.firstIndex { $0.kind == .steps }!].start = bedtime.addingTimeInterval(-10_000)
        let result = try summary(value)
        #expect(Set(result.unavailableKinds) == Set([.workout, .steps]))
        #expect(result.groups.isEmpty)
        #expect(!result.emptyKinds.contains(.workout))
        #expect(!result.emptyKinds.contains(.steps))
    }
    @Test func unavailableReadCannotCarryCachedRecords() {
        var value = snapshot([observation()]); value.reads[0].state = .unavailable
        #expect(throws: DaytimeContextError.self) { try value.validate() }
    }
    @Test func invalidClockUnitsSourceAndReadCoverageAreRejected() {
        for change in [0, 1, 2, 3, 4, 5] {
            var value = snapshot([observation()])
            switch change {
            case 0: value.observations[0].value = .nan
            case 1: value.observations[0].value = 1000
            case 2: value.observations[0].source.identifier = ""
            case 3: value.observations[0].end = value.importedAt.addingTimeInterval(1)
            case 4: value.reads.removeLast()
            default: value.timeZone = "Invalid/Zone"
            }
            #expect(throws: DaytimeContextError.self) { try value.validate() }
        }
    }
    @Test func futureImportsAndFutureBedtimesAreRejected() {
        #expect(throws: DaytimeContextError.self) { try DaytimeContextSummary.make(snapshot: snapshot(), bedtime: bedtime, now: bedtime) }
        #expect(throws: DaytimeContextError.self) {
            try DaytimeContextSummary.make(snapshot: snapshot(), bedtime: bedtime.addingTimeInterval(172_800), now: bedtime.addingTimeInterval(86_400))
        }
    }
    @Test func elapsedWindowIsStableAcrossFallDSTAndRecordedTravelZones() throws {
        var value = snapshot([observation(.steps, start: -86_400, end: -86_000, value: 200)])
        value.observations[0].recordedTimeZone = "Europe/Rome"
        let result = try summary(value)
        #expect(result.bedtime.timeIntervalSince(result.windowStart) == 86_400)
        #expect(result.groups.first?.total == 200)
    }
    @Test func recordOrderDoesNotChangeSummary() throws {
        let records = [observation(.steps, start: -10_000, end: -9000, value: 100, source: watch),
                       observation(.steps, start: -8000, end: -7000, value: 200, source: watch),
                       observation(.steps, start: -7000, end: -6000, value: 300, source: phone)]
        #expect(try summary(snapshot(records)) == summary(snapshot(Array(records.reversed()))))
    }
    @Test func instantaneousHealthQuantitiesRemainReadableWithoutInventedDuration() throws {
        let point = observation(.steps, start: -100, end: -100, value: 20)
        #expect(try summary(snapshot([point])).groups.first?.total == 20)
        var workout = point; workout.kind = .workout
        #expect(throws: DaytimeContextError.self) { try snapshot([workout]).validate() }
    }
    @Test func distinctRecordsAtTheSameInstantAreAmbiguousRatherThanAdditive() throws {
        let first = observation(.steps, start: -100, end: -100, value: 20)
        let second = observation(.steps, start: -100, end: -100, value: 25)
        let result = try summary(snapshot([first, second])).groups.first
        #expect(result?.total == nil); #expect(result?.excludedOverlaps == 2)
    }
}
