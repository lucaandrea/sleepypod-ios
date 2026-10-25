import Foundation
import Testing
@testable import FreeSleepKit

struct RecordEditingTests {
    @Test func recordChangesEncodeOriginalIdentityAndValidateElapsedTime() throws {
        let episode = try #require(SleepDemo.shared?.analytics.nights.last)
        let identity = SleepRecordIdentity(side: .right, episode: episode)
        let start = try #require(EpisodeDetail.date("2026-11-01T01:30:00-07:00"))
        let end = try #require(EpisodeDetail.date("2026-11-01T01:30:00-08:00"))
        let change = try SleepRecordChange(identity: identity, start: start, end: end)
        #expect(end.timeIntervalSince(start) == 3600)
        #expect(SleepRecordChange.valid(start: end, end: start) == false)
        #expect(SleepRecordChange.valid(start: start, end: start.addingTimeInterval(72 * 3600 + 1)) == false)
        #expect(SleepRecordChange.valid(start: start.addingTimeInterval(0.1), end: start.addingTimeInterval(0.9)) == false)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        #expect(json["side"] as? String == "right")
        #expect(json["entered_bed_at"] as? String == "2026-11-01T08:30:00.000Z")
        #expect((json["expected"] as? [String: String])?["entered_bed_at"] == episode.startedAt)
        #expect(Set(json.keys) == ["side", "expected", "entered_bed_at", "left_bed_at"])
    }
    @MainActor @Test func editablePreviewMatchesSharedAnalyticsAndCoachingBeforeChanges() throws {
        let fixture = try #require(SleepDemo.shared)
        let history = DemoSleepHistory()
        for days in [7, 30, 90] {
            let computed = try #require(history.analytics(side: .left, days: days))
            #expect(computed == fixture.ranges[String(days)])
            let coach = DemoSleepSummary.coaching(computed, provider: "rules")
            #expect(coach.observations == fixture.coaching[String(days)]?.observations)
            #expect(coach.suggestions == fixture.coaching[String(days)]?.suggestions)
            #expect(coach.grounding == fixture.coaching[String(days)]?.grounding)
        }
    }
    @MainActor @Test func editsAndDeletesPreservePartnerAndRawReadingsAndRejectStaleSnapshots() throws {
        let history = DemoSleepHistory()
        let original = try history.detail(id: 14, side: .left)
        let identity = SleepRecordIdentity(side: .left, episode: original.episode)
        let start = try #require(EpisodeDetail.date(original.episode.startedAt))
        let end = try #require(EpisodeDetail.date(original.episode.endedAt))
        let change = try SleepRecordChange(identity: identity, start: start.addingTimeInterval(1800), end: end.addingTimeInterval(-1800))
        try history.change(id: 14, change: change)
        let changed = try history.detail(id: 14, side: .left)
        #expect(changed.episode.windowMinutes == 410)
        #expect(changed.episode.occupiedMinutes == 395)
        #expect(changed.episode.exits == 1)
        #expect(changed.samples.count < original.samples.count)
        #expect(try history.detail(id: 14, side: .right).episode == original.episode)
        #expect(throws: (any Error).self) { try history.change(id: 14, change: change) }
        #expect(throws: (any Error).self) { try history.delete(id: 14, identity: identity) }
        let currentIdentity = SleepRecordIdentity(side: .left, episode: changed.episode)
        try history.change(id: 14, change: SleepRecordChange(identity: currentIdentity, start: start, end: end))
        #expect(try history.detail(id: 14, side: .left).samples.count == original.samples.count)
        try history.delete(id: 14, identity: identity)
        #expect(throws: (any Error).self) { try history.detail(id: 14, side: .left) }
        #expect(history.analytics(side: .right, days: 30)?.episodes?.count == 15)
        #expect(history.analytics(side: .left, days: 30)?.episodes?.count == 14)
        #expect(history.analytics(side: .left, days: 30)?.nights.last?.id == 15)
    }
}
