import XCTest

@MainActor final class BedWidgetUITests: XCTestCase {
    func testSmallShowsBothTargetsAndSavedAge() { verify(family: "small", state: "split", large: false) }
    func testMediumShowsWakePlan() { verify(family: "medium", state: "split", large: false) }
    func testLockScreenShowsSavedTargets() { verify(family: "lock", state: "split", large: false) }
    func testLargeTextOffState() { verify(family: "small", state: "off", large: true) }
    func testLargeTextSplitTargets() { verify(family: "small", state: "split", large: true) }
    func testLargeTextSavedWake() { verify(family: "small", state: "overnight", large: true) }
    func testLargeTextMissingAccount() { verify(family: "small", state: "missing", large: true) }
    func testExpiredSnapshotHidesAllTargets() { verify(family: "small", state: "expired", large: false) }
    func testMissingAccountHasNoInventedTargets() { verify(family: "medium", state: "missing", large: false) }
    func testStandByRetainsSavedWakeButWithdrawsOldTargets() { verify(family: "small", state: "overnight", large: false) }

    private func verify(family: String, state: String, large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--bed-widget-fixture", "-apiBackend", "demo", "-onboardingComplete", "YES",
            "-healthSyncEnabled", "NO", "-household.personalWorkspaceActive", "NO", "-uiWidgetFamily", family,
            "-uiWidgetState", state, "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Widget previews"].waitForExistence(timeout: 30))
        if large {
            let prefix = state == "missing" ? "Open sleepypod to refresh" : state == "overnight" ? "Saved wake, right side" : "Saved bed target, \(state == "off" ? "Off" : "68°F / 88°F")"
            let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            let preview = app.otherElements["widget.productionPreview"]
            XCTAssertTrue(preview.exists)
            XCTAssertGreaterThanOrEqual(status.frame.minY, preview.frame.minY)
            XCTAssertLessThanOrEqual(status.frame.maxY, preview.frame.maxY)
            shot(app, name: "Widget-small-\(state)-large"); app.terminate(); return
        }
        let absent = ["expired", "missing"].contains(state)
        let status = state == "overnight" ? app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved wake, right side'")).firstMatch
            : app.staticTexts[absent ? "Open sleepypod" : state == "off" ? "Off" : family == "lock" ? "Target 68°F / 88°F" : "68°F / 88°F"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(status.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(status.frame.maxX, app.frame.maxX)
        let preview = app.otherElements["widget.productionPreview"]
        XCTAssertGreaterThanOrEqual(status.frame.minY, preview.frame.minY)
        XCTAssertLessThanOrEqual(status.frame.maxY, preview.frame.maxY)
        if absent || state == "overnight" { XCTAssertFalse(app.staticTexts["68°F / 88°F"].exists) }
        else {
            XCTAssertTrue(app.staticTexts["Both sides"].exists)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved '")).firstMatch.exists)
        }
        if family == "medium", !absent { XCTAssertTrue(app.staticTexts["Saved wake plan"].exists) }
        shot(app, name: "Widget-\(family)-\(state)-default")
        app.terminate()
    }
    private func shot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
