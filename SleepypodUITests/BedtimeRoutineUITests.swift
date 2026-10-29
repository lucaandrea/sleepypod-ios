import XCTest

@MainActor final class BedtimeRoutineUITests: XCTestCase {
    func testCreateReviewCopyCancelAndDeleteWholeNightWithoutCrossingSides() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "routines", "-appearance", "Dark"]
        app.launch()
        let monday = app.buttons["routines.edit.monday"]
        XCTAssertTrue(monday.waitForExistence(timeout: 15)); capture(app, "Routines-empty")
        monday.tap(); let active = app.switches["routine.enabled"]
        XCTAssertTrue(active.waitForExistence(timeout: 5)); reveal(active, app); active.tap(); capture(app, "Routines-power-draft")
        let phases = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Custom temperature phases")).firstMatch; reveal(phases, app); phases.tap()
        let add = app.buttons["routine.phase.add"]; reveal(add, app); add.tap()
        let phaseDone = app.buttons["routine.phase.done"]; XCTAssertTrue(phaseDone.waitForExistence(timeout: 5)); capture(app, "Routines-phase-draft"); phaseDone.tap()
        let include = app.switches["routine.alarm.include"]; reveal(include, app); include.tap()
        let advanced = app.buttons["Pattern, intensity and snooze"]; reveal(advanced, app); advanced.tap()
        let snooze = app.steppers["routine.alarm.snooze"].buttons["routine.alarm.snooze-Increment"]
        reveal(snooze, app); snooze.tap(); XCTAssertTrue(app.staticTexts["360 sec"].exists); capture(app, "Routines-alarm-draft")
        let tuesday = app.switches["routine.copy.tuesday"]; reveal(tuesday, app); tuesday.tap(); capture(app, "Routines-copy-draft")
        app.buttons["routine.commit"].tap()
        XCTAssertTrue(app.navigationBars["Review routine"].waitForExistence(timeout: 5)); capture(app, "Routines-reviewed")
        app.buttons["routine.commit"].tap()
        XCTAssertTrue(monday.waitForExistence(timeout: 6)); XCTAssertTrue(app.buttons["routines.delete.monday"].exists)
        let deleteTuesday = app.buttons["routines.delete.tuesday"]; reveal(deleteTuesday, app); XCTAssertTrue(deleteTuesday.exists); capture(app, "Routines-copied")
        reveal(monday, app); monday.tap()
        XCTAssertTrue(active.waitForExistence(timeout: 5)); reveal(active, app); active.tap(); app.navigationBars["Edit routine"].buttons["Cancel"].tap()
        XCTAssertTrue(monday.waitForExistence(timeout: 5)); monday.tap()
        XCTAssertTrue(active.waitForExistence(timeout: 5)); XCTAssertEqual(active.value as? String, "1"); reveal(advanced, app); advanced.tap(); XCTAssertTrue(app.staticTexts["360 sec"].exists)
        app.navigationBars["Edit routine"].buttons["Cancel"].tap()
        let side = app.segmentedControls["routines.side"]; reveal(side, app); side.buttons["Right"].tap()
        XCTAssertTrue(monday.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["routines.delete.monday"].exists); capture(app, "Routines-right-empty")
        side.buttons["Left"].tap()
        let deleteMonday = app.buttons["routines.delete.monday"]; XCTAssertTrue(deleteMonday.waitForExistence(timeout: 5)); reveal(deleteMonday, app); deleteMonday.tap()
        let confirm = app.buttons["Delete Monday"]; XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: deleteMonday); waitForExpectations(timeout: 6)
        XCTAssertTrue(deleteTuesday.exists); capture(app, "Routines-deleted-one-night")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<50 {
            let editor = app.scrollViews["routine.editor.scroll"]
            let scroll = editor.exists ? editor : app.scrollViews["routines.scroll"]
            let bounds = scroll.frame.intersection(app.frame)
            let top = max(bounds.minY + 12, app.navigationBars.firstMatch.frame.maxY + 12)
            let frame = element.exists ? element.frame : .zero
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 20))
            if element.exists, element.isHittable, visible.contains(frame) { return }
            let direction = frame.isEmpty || frame.midY >= visible.midY ? 1.0 : -1.0
            let distance = min(0.4, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier), frame \(element.frame), hittable \(element.isHittable)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) { let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}
