import XCTest

@MainActor final class WatchRecordingUITests: XCTestCase {
    func testMissingRecordsHaveGuidanceWithoutClaimingZeroSleep() { verify(large: false, available: false) }
    func testLargeTextShowsReturnedIntervalsAndPrivateImportScope() { verify(large: true, available: true) }

    private func verify(large: Bool, available: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", "sleep", "-household.personalWorkspaceActive", "NO",
                               "-uiWatchRecording", available ? "available" : "missing", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let open = app.buttons["watch.recording.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 30)); reveal(open, in: app); open.tap()
        let status = app.staticTexts["watch.recording.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, available ? "Watch sleep records are available" : "No Watch sleep returned yet")
        XCTAssertLessThanOrEqual(status.frame.maxX, app.frame.maxX)
        shot(app, name: large ? "Watch-large-overview" : "Watch-missing-overview")
        let refresh = app.buttons["watch.recording.refresh"]
        reveal(refresh, in: app); XCTAssertFalse(refresh.isEnabled)
        let help = app.buttons["watch.recording.help"]
        reveal(help, in: app); help.tap()
        let access = app.staticTexts["3. Review sleepypod’s read access"]
        reveal(access, in: app)
        shot(app, name: large ? "Watch-large-guidance" : "Watch-missing-guidance")
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<30 where !element.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.isHittable)
    }
    private func shot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
