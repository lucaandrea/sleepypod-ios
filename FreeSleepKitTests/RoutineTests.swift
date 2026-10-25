import Foundation
import Testing
@testable import FreeSleepKit

struct RoutineTests {
    @MainActor @Test func sharedDemoFixtureMatchesOvernightTimeline() throws {
        let book = try #require(RoutineWorkspace().demoBook)
        for week in book.values { for schedule in week.values { #expect(RoutinePlan.problems(schedule).isEmpty) } }
        var routine = try #require(book["left"]?["monday"])
        let points = RoutinePlan.points(routine)
        #expect(points.map(\.time) == ["22:00", "23:00", "02:00", "06:00", "08:00"])
        #expect(points.map(\.minutes) == [0, 60, 240, 480, 600])
        #expect(points.map(\.temperature) == [80, 78, 76, 80, 80])
        routine.power.on = "13:00"; routine.power.off = "19:00"; routine.temperatures = ["14:00": 78]; routine.alarm.time = "18:00"
        #expect(RoutinePlan.problems(routine).isEmpty)
        routine.alarm.time = "19:00"; #expect(RoutinePlan.problems(routine).count == 1)
        routine.power.enabled = false; #expect(RoutinePlan.problems(routine).isEmpty)
    }
    @MainActor @Test func copyingWeekdaysPreservesOtherSideAndRejectsStaleTargets() throws {
        var book = try #require(RoutineWorkspace().demoBook)
        let before = book
        #expect(RoutinePlan.hasCompleteWeek(book))
        var incomplete = book; incomplete["right"]?["sunday"] = nil
        #expect(!RoutinePlan.hasCompleteWeek(incomplete))
        let days = Array(RoutinePlan.days.prefix(5))
        var selected = try #require(book["left"]?["monday"]); selected.temperatures = [:]; selected.power.enabled = false
        let expected = Dictionary(uniqueKeysWithValues: days.map { ($0, book["left"]![$0]!) })
        let request = RoutineSave(side: .left, days: days, schedule: selected, expected: expected)
        try RoutinePlan.apply(request, to: &book)
        #expect(book["right"] == before["right"])
        #expect(book["left"]?["saturday"] == before["left"]?["saturday"])
        #expect(book["left"]?["sunday"] == before["left"]?["sunday"])
        #expect(days.allSatisfy { book["left"]?[$0] == selected })
        #expect(throws: (any Error).self) { try RoutinePlan.apply(request, to: &book) }
        #expect(book["left"]?["monday"] == selected)
        let duplicate = RoutineSave(side: .left, days: ["monday", "monday"], schedule: selected, expected: ["monday": selected])
        #expect(throws: (any Error).self) { try RoutinePlan.apply(duplicate, to: &book) }
        let missing = RoutineSave(side: .left, days: ["monday", "tuesday"], schedule: selected, expected: ["monday": selected])
        #expect(throws: (any Error).self) { try RoutinePlan.apply(missing, to: &book) }
    }
    @MainActor @Test func draftsSurviveSelectionAndPreserveOriginalAcrossRefreshes() throws {
        let workspace = RoutineWorkspace()
        let original = DailySchedule.empty
        var edited = original; edited.power.onTemperature = 76
        workspace.put("pod|left|monday", original: original, value: edited, copies: [])
        workspace.day = "tuesday"
        workspace.put("pod|right|monday", original: original, value: edited, copies: ["friday"])
        var refreshed = original; refreshed.alarm.duration = 120
        edited.power.onTemperature = 78
        workspace.put("pod|left|monday", original: refreshed, value: edited, copies: [])
        #expect(workspace.drafts["pod|left|monday"]?.original == original)
        #expect(workspace.drafts["pod|left|monday"]?.value.power.onTemperature == 78)
        workspace.clear(["pod|right|monday"])
        #expect(workspace.drafts.count == 1)
        workspace.put("pod|left|monday", original: refreshed, value: original, copies: [])
        #expect(workspace.drafts.isEmpty)
    }
    @MainActor @Test func demoRoutineSaveUpdatesTonightsAlarmForOnlyThatSide() throws {
        let workspace = RoutineWorkspace()
        let book = try #require(workspace.demoBook)
        let original = try #require(book["left"]?["monday"])
        let now = try #require(AlarmPreview.date("2026-10-13T05:30:00Z"))
        let alarms = DemoAlarms(workspace: workspace)
        #expect(alarms.preview(side: .left, now: now).alarm?.time == "07:00")
        var modified = original; modified.alarm.time = "07:30"
        _ = try workspace.saveDemo(.init(side: .left, days: ["monday"], schedule: modified, expected: ["monday": original]))
        #expect(alarms.preview(side: .left, now: now).alarm?.time == "07:30")
        #expect(alarms.preview(side: .left, now: now).alarm?.scheduleDay == "monday")
        #expect(alarms.preview(side: .right, now: now).alarm?.time == "07:00")
    }
}
