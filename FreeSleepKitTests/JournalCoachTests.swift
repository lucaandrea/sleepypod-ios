import Foundation
import Testing
@testable import FreeSleepKit

struct JournalCoachTests {
    @Test func datesFollowPodCalendarAcrossMidnightAndDaylightSaving() throws {
        let instant = try #require(EpisodeDetail.date("2026-10-14T06:30:00Z"))
        #expect(JournalDate.key(instant, timeZone: "America/Los_Angeles") == "2026-10-13")
        #expect(JournalDate.key(instant, timeZone: "Asia/Tokyo") == "2026-10-14")
        for key in ["2026-03-08", "2026-11-01", "2024-02-29"] {
            let date = try #require(JournalDate.date(key, timeZone: "America/Los_Angeles"))
            #expect(JournalDate.key(date, timeZone: "America/Los_Angeles") == key)
        }
        #expect(JournalDate.date("2026-02-30", timeZone: "UTC") == nil)
        #expect(InputText.limit(String(repeating: "🙂", count: 251), to: 500).utf16.count == 500)
        #expect(InputText.limit("a👨‍👩‍👧‍👦b", to: 10) == "a")
    }
    @MainActor @Test func journalDraftsSurviveContextChangesAndLateSavesKeepNewerEdits() {
        let workspace = JournalWorkspace()
        var entry = JournalEntry(date: "2026-10-13", side: "left"); entry.notes = "Before"
        workspace.put("pod:left:date", value: entry)
        #expect(workspace.drafts["pod:right:date"] == nil)
        #expect(workspace.drafts["other:left:date"] == nil)
        #expect(workspace.beginSave("pod:left:date"))
        #expect(!workspace.beginSave("pod:left:date"))
        var changed = entry; changed.notes = "Newer draft"; workspace.put("pod:left:date", value: changed)
        workspace.clear("pod:left:date", expected: entry)
        #expect(workspace.drafts["pod:left:date"]?.notes == "Newer draft")
        workspace.finishSave("pod:left:date"); #expect(workspace.saving.isEmpty)
        workspace.clear("pod:left:date", expected: changed); #expect(workspace.drafts.isEmpty)
    }
    @MainActor @Test func demoJournalKeepsOldDatesAndSeparatesPartnerRecords() {
        let workspace = JournalWorkspace()
        var entry = JournalEntry(date: "2000-01-02", side: "left"); entry.notes = "  Old note  "
        _ = workspace.saveDemo("demo|left|2000-01-02", value: entry)
        let result = workspace.demoJournal(key: "demo|left|2000-01-02", date: entry.date, side: "left", days: 7)
        #expect(result.selected?.notes == "Old note")
        #expect(result.patterns.associations.isEmpty)
        #expect(workspace.demoJournal(key: "demo|right|2000-01-02", date: entry.date, side: "right", days: 7).selected == nil)
    }
    @MainActor @Test func supersededAndCancelledCoachingCannotPublish() async throws {
        let result = try #require(SleepDemo.shared?.coaching["30"])
        let session = CoachSession()
        await session.run { session.invalidate(); return result }
        #expect(session.result == nil); #expect(!session.busy)
        let task = Task { await session.run { try await Task.sleep(for: .milliseconds(200)); return result } }
        await Task.yield(); task.cancel(); await task.value
        #expect(session.result == nil); #expect(session.error == nil); #expect(!session.busy)
        await session.run { result }; #expect(session.result?.headline == result.headline)
        session.invalidate(); #expect(session.result == nil)
    }
    @Test func demoCoachingUsesTheSameComputedMetricsAsTheSelectedRange() throws {
        let fixture = try #require(SleepDemo.shared)
        for days in ["7", "30", "90"] {
            let source = try #require(fixture.ranges[days]?.summary.averageOccupiedMinutes)
            let result = try #require(fixture.coaching[days])
            #expect(result.observations.contains { $0.contains("\(Int(source.rounded())) minutes") })
            #expect(result.provider == "rules")
        }
    }
}
