import Foundation
import Testing
@testable import FreeSleepKit

struct AlarmTests {
    @Test func shortcutEditsRequireAnOccurrenceAndExplicit24HourTime() throws {
        let preview = AlarmPreview(side: .right, timeZone: "Europe/London", state: "scheduled",
            alarm: .init(at: "2026-10-15T06:00:00.000Z", time: "07:00", scheduleDay: "wednesday", source: "routine"))
        let change = try AlarmChange.validated(preview: preview, action: .time, time: "21:15")
        #expect(change.side == .right)
        #expect(change.expectedAt == preview.alarm?.at)
        for time in ["7:00", "07:00 PM", "24:00", "07:60", " 07:00", ""] {
            #expect(throws: (any Error).self) { try AlarmChange.validated(preview: preview, action: .time, time: time) }
        }
        #expect(throws: (any Error).self) { try AlarmChange.validated(preview: preview, action: .restore) }
        let paused = AlarmPreview(side: .right, timeZone: "Europe/London", state: "paused", expiresAt: "2026-10-15T06:02:00.000Z", overrideRevision: UUID().uuidString)
        #expect(throws: (any Error).self) { try AlarmChange.validated(preview: paused, action: .disable) }
        let restore = try AlarmChange.validated(preview: paused, action: .restore)
        #expect(restore.expectedExpiresAt == paused.expiresAt)
        #expect(restore.expectedRevision == paused.overrideRevision)
        #expect(restore.expectedAt == nil)
    }

    @Test func previewUsesPodTimezoneAndKeepsClockTimeIn24Hours() throws {
        let data = Data(#"{"side":"left","timeZone":"America/Los_Angeles","state":"scheduled","expiresAt":null,"alarm":{"at":"2026-10-14T20:30:00.000Z","time":"13:30","scheduleDay":"wednesday","source":"routine"}}"#.utf8)
        let preview = try JSONDecoder().decode(AlarmPreview.self, from: data)
        #expect(preview.title == "1:30 PM")
        #expect(preview.detail == "Wed, Oct 14 · America/Los_Angeles")
        for time in ["00:00", "07:00", "13:30", "23:59"] { #expect(AlarmClock.time(AlarmClock.date(time)) == time) }
        let change = AlarmChange(preview: preview, action: .time, time: "14:15")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: String])
        #expect(json["time"] == "14:15")
        #expect(json["side"] == "left")
        #expect(json["expectedAt"] == preview.alarm?.at)
        #expect(json["expectedExpiresAt"] == nil)
    }

    @MainActor @Test func demoChangesAreSideScopedAndRestoreTheRoutine() throws {
        let service = DemoAlarms()
        let now = try #require(AlarmPreview.date("2026-10-14T05:00:00Z"))
        let original = service.preview(side: .left, now: now)
        let changed = try service.change(.init(preview: original, action: .time, time: "08:00"), now: now)
        #expect(changed.alarm?.time == "08:00")
        #expect(changed.alarm?.source == "override")
        #expect(service.preview(side: .right, now: now).alarm?.time == "07:00")
        #expect(throws: (any Error).self) { try service.change(.init(preview: original, action: .disable), now: now) }
        let paused = try service.change(.init(preview: changed, action: .disable), now: now)
        #expect(paused.state == "paused")
        let restored = try service.change(.init(preview: paused, action: .restore), now: now)
        #expect(restored.alarm?.at == original.alarm?.at)
        #expect(restored.expiresAt == nil)
        let early = try service.change(.init(preview: restored, action: .time, time: "06:00"), now: now)
        let later = try service.change(.init(preview: early, action: .time, time: "06:30"), now: now)
        #expect(early.expiresAt == later.expiresAt)
        #expect(early.overrideRevision != later.overrideRevision)
        #expect(throws: (any Error).self) { try service.change(.init(preview: early, action: .restore), now: now) }
    }

    @MainActor @Test func demoRejectsDstAmbiguityAndExpiredActions() throws {
        let service = DemoAlarms()
        let now = try #require(AlarmPreview.date("2026-11-01T06:00:00Z"))
        let original = service.preview(side: .left, now: now)
        #expect(throws: (any Error).self) { try service.change(.init(preview: original, action: .time, time: "01:30"), now: now) }
        let expired = try #require(AlarmPreview.date(original.alarm!.at)).addingTimeInterval(1)
        #expect(throws: (any Error).self) { try service.change(.init(preview: original, action: .disable), now: expired) }
    }
}
