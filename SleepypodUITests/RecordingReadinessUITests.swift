import XCTest

@MainActor final class RecordingReadinessUITests: XCTestCase {
    func testSleepShowsRecordingScopeAndReadOnlyChecks() { verify(large: false) }
    func testLargeTextKeepsChecksReachable() { verify(large: true) }

    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", "sleep", "-household.personalWorkspaceActive", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let title = app.staticTexts["recording.readiness.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        reveal(title, in: app)
        XCTAssertEqual(title.label, "Recording checks are incomplete")
        XCTAssertGreaterThanOrEqual(title.frame.minX, 0)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)
        let details = app.buttons["recording.readiness.details"]
        reveal(details, in: app); details.tap()
        let storage = app.staticTexts["Recording storage"]
        reveal(storage, in: app)
        XCTAssertTrue(storage.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = large ? "Recording-large-text" : "Recording-checks"
        shot.lifetime = .keepAlways; add(shot)
        let refresh = app.buttons["recording.readiness.refresh"]
        reveal(refresh, in: app)
        XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        XCTAssertFalse(app.buttons["Restart piezo processor"].exists)
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 where !element.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.isHittable)
    }
}
