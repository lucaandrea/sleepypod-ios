import Foundation
import Testing
@testable import FreeSleepKit

@MainActor
struct PreferencesTests {
    @Test func sharedPreferencesValidateNamesUnitsAndClock() throws {
        let fixture = try #require(DeviceDemo.shared)
        #expect(fixture.preferences.preferences.valid)
        #expect(fixture.preferences.timeZones.contains("Europe/London"))
        #expect(fixture.health.count == 6)
        var draft = fixture.preferences.preferences
        draft.left.name = String(repeating: "😀", count: 11); #expect(!draft.valid)
        draft.left.name = "  "; #expect(!draft.valid)
        draft.left.name = " New name "; #expect(draft.normalized.left.name == "New name")
        for clock in ["7:00", "24:00", "12:60", ""] { draft.primePodDaily.time = clock; #expect(!draft.valid) }
    }
    @Test func savingUsesOriginalIdentityAndOnlyThePreferencesContract() async throws {
        let snapshot = try #require(DeviceDemo.shared?.preferences)
        var saved = snapshot; saved.preferences.left.name = "Sleeper"
        let reply = try JSONEncoder().encode(saved)
        let transport = try IntentHTTPFixture { _ in .init(data: reply) }; defer { transport.close() }
        let workspace = PreferencesWorkspace()
        await workspace.load { snapshot }
        workspace.draft?.left.name = " Sleeper "
        let result = await workspace.save { change in try await transport.client.postReturning("settings/preferences", body: change) }
        #expect(result == saved); #expect(!workspace.dirty); #expect(workspace.message == "Device settings saved.")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/settings/preferences"); #expect(request.httpMethod == "POST")
        let bytes = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(body.keys) == ["podID", "expected", "preferences"])
        #expect(body["podID"] as? String == snapshot.podID)
        let original = try #require(body["expected"] as? [String: Any])
        #expect((original["left"] as? [String: Any])?["name"] as? String == snapshot.preferences.left.name)
        #expect(transport.requests.count == 1)
    }
    @Test func conflictingSaveRetainsDraftAndBlocksDuplicateOrLateConnectionResults() async throws {
        let snapshot = try #require(DeviceDemo.shared?.preferences)
        let workspace = PreferencesWorkspace(); await workspace.load { snapshot }
        workspace.draft?.left.name = "Draft"
        let failed = await workspace.save { _ in throw PodError.message("Edited elsewhere") }
        #expect(failed == nil); #expect(workspace.draft?.left.name == "Draft"); #expect(workspace.failure == "Edited elsewhere")
        var writes = 0
        let late = await workspace.save { change in
            writes += 1
            let duplicate = await workspace.save { _ in writes += 1; return snapshot }
            #expect(duplicate == nil)
            workspace.invalidate()
            var saved = snapshot; saved.preferences = change.preferences; return saved
        }
        #expect(late == nil); #expect(writes == 1); #expect(workspace.snapshot == nil); #expect(!workspace.busy)
        await workspace.load { workspace.invalidate(); return snapshot }
        #expect(workspace.snapshot == nil)
    }
    @Test func resetRestoresSnapshotAndChangedPodCannotReportSuccess() async throws {
        let snapshot = try #require(DeviceDemo.shared?.preferences)
        let workspace = PreferencesWorkspace(); await workspace.load { snapshot }
        workspace.draft?.temperatureFormat = "celsius"; workspace.resetDraft()
        #expect(workspace.draft == snapshot.preferences); #expect(!workspace.dirty)
        workspace.draft?.temperatureFormat = "celsius"
        let result = await workspace.save { _ in var other = snapshot; other.podID = "different"; return other }
        #expect(result == nil); #expect(workspace.failure?.contains("identity changed") == true)
        #expect(workspace.draft?.temperatureFormat == "celsius")
    }
    @Test func demoTimezoneChangesRecomputeWakeDatesAndAwayAlarms() throws {
        let history = DemoSleepHistory(); history.timeZone = "Asia/Tokyo"
        let detail = try history.detail(id: 15, side: .left)
        #expect(detail.timeZone == "Asia/Tokyo"); #expect(detail.episode.date == "2026-10-14")
        #expect(history.analytics(side: .left, days: 30)?.timeZone == "Asia/Tokyo")
        let alarms = DemoAlarms(); alarms.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(alarms.preview(side: .left).timeZone == "Asia/Tokyo")
        let now = try #require(AlarmPreview.date("2026-10-14T12:00:00Z"))
        let changed = try alarms.change(AlarmChange(preview: alarms.preview(side: .left, now: now), action: .time, time: "08:00"), now: now)
        alarms.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let relocated = alarms.preview(side: .left, now: now)
        #expect(relocated.alarm?.at == changed.alarm?.at)
        #expect(relocated.timeZone == "America/Los_Angeles"); #expect(relocated.alarm?.time == "16:00")
        alarms.away[.left] = true
        #expect(alarms.preview(side: .left).state == "away")
        #expect(alarms.preview(side: .right).state == "scheduled")
    }
}
