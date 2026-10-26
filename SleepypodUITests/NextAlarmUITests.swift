import XCTest
import UIKit

@MainActor final class NextAlarmUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false; let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "", "-temperatureLayout", "cards", "-tempControl", "dial", "-uiNextAlarmScenario", scenario,
            "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.buttons["Temp"].firstMatch.waitForExistence(timeout: 15))
        reveal(app.buttons["nextAlarm.reload"], app); return app
    }
    func testSkipFollowingRestoreTimeDraftAndSeparateWeeklyEditor() {
        let app = launch("scheduled"), skip = app.buttons["nextAlarm.skip"]
        reveal(skip, app, searchUp: true); capture(app, "Occurrence-scheduled"); skip.tap()
        reveal(app.staticTexts["nextAlarm.following"], app, searchUp: true); XCTAssertTrue(app.staticTexts["nextAlarm.skipped"].exists); capture(app, "Occurrence-skipped")
        let restore = app.buttons["nextAlarm.restore"]; reveal(restore, app); restore.tap()
        let change = app.buttons["nextAlarm.change"]; reveal(change, app, searchUp: true); change.tap()
        reveal(app.datePickers["nextAlarm.time"], app); capture(app, "Occurrence-time-draft")
        let cancel = app.buttons["nextAlarm.cancel"]; reveal(cancel, app); cancel.tap()
        let weekly = app.buttons["nextAlarm.weekly"]; reveal(weekly, app); weekly.tap()
        XCTAssertTrue(app.navigationBars["Edit alarm"].waitForExistence(timeout: 3)); capture(app, "Occurrence-weekly-editor")
        XCTAssertTrue(app.switches["Alarm enabled"].exists); app.navigationBars.buttons["Cancel"].tap()
    }
    func testChangeTimeSavesOnlyTheSelectedWakeDate() {
        let app = launch("scheduled"), change = app.buttons["nextAlarm.change"]
        reveal(change, app, searchUp: true); change.tap()
        let picker = app.datePickers["nextAlarm.time"]; reveal(picker, app); picker.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 4))
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "8")
        app.coordinate(withNormalizedOffset: .init(dx: 0.04, dy: 0.20)).tap()
        let save = app.buttons["nextAlarm.save"]; reveal(save, app); save.tap()
        reveal(app.staticTexts["nextAlarm.notice"], app, searchUp: true)
        XCTAssertTrue(app.staticTexts["nextAlarm.notice"].label.contains("One-time change saved"))
        XCTAssertTrue(app.staticTexts["8:00 AM"].exists)
        capture(app, "Occurrence-time-saved")
    }
    func testUncertainSaveReadsBackWithoutRepeatingAndShowsPendingTimerState() {
        let app = launch("lost-save"), skip = app.buttons["nextAlarm.skip"]
        reveal(skip, app, searchUp: true); skip.tap(); XCTAssertFalse(skip.isEnabled)
        reveal(app.staticTexts["nextAlarm.error"], app); capture(app, "Occurrence-uncertain")
        let reload = app.buttons["nextAlarm.reload"]; reveal(reload, app); reload.tap()
        reveal(app.staticTexts["nextAlarm.skipped"], app, searchUp: true); capture(app, "Occurrence-readback"); app.terminate()
        let pending = launch("pending"), pendingSkip = pending.buttons["nextAlarm.skip"]; reveal(pendingSkip, pending, searchUp: true); pendingSkip.tap()
        reveal(pending.staticTexts["nextAlarm.notice"], pending); XCTAssertTrue(pending.staticTexts["nextAlarm.notice"].label.contains("registration is pending")); capture(pending, "Occurrence-pending-timer")
    }
    func testUnavailableConflictingAndAttemptedStatesStayExplicit() {
        for scenario in ["normal", "conflicting", "unknown", "away", "offline"] {
            let app = launch(scenario)
            let skip = app.buttons["nextAlarm.skip"]
            if skip.exists { XCTAssertFalse(skip.isEnabled) }
            capture(app, "Occurrence-\(scenario)"); app.terminate()
        }
    }
    func testSettingsOpensNativeNextAlarmForBothSides() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings", "-uiNextAlarmScenario", "scheduled",
            "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let link = app.buttons["Next alarm"]; reveal(link, app); link.tap()
        XCTAssertTrue(app.navigationBars["Next alarm"].waitForExistence(timeout: 5))
        let left = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "NEXT ALARM · LEFT")).firstMatch
        let right = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "NEXT ALARM · RIGHT")).firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 3)); XCTAssertTrue(left.isHittable); capture(app, "Occurrence-settings-left")
        reveal(right, app); capture(app, "Occurrence-settings-right")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, searchUp: Bool = false) {
        let scroll = app.scrollViews.firstMatch
        for attempt in 0..<45 {
            let bounds = app.frame.insetBy(dx: 0, dy: app.frame.width > 600 ? 100 : 160)
            let frame = element.exists ? element.frame : .zero
            if element.exists, element.isHittable, bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            let upward = frame.isEmpty ? !(searchUp && attempt < 20) : frame.midY > bounds.midY
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: upward ? 0.72 : 0.30)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: upward ? 0.30 : 0.72)))
        }
        XCTFail("Cannot reach expected alarm control")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
