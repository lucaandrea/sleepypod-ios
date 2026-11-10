import XCTest

@MainActor final class TonightUITests: XCTestCase {
    func testTonightOffersAutopilotAndActualAlarmReview() { verify(large: false) }
    func testTonightSupportsAccessibilityTextAndStage() { verify(large: true) }
    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "temp",
                               "-household.personalWorkspaceActive", "NO", "-appearance", large ? "Light" : "Dark",
                               "-tempControl", "dial", "-temperatureDisplay", "degrees",
                               "-temperatureLayout", large ? "stage" : "cards",
                               "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["Tonight"].firstMatch.waitForExistence(timeout: 30))
        let autopilot = app.buttons["tonight.autopilot"]
        reveal(autopilot, app: app)
        XCTAssertLessThanOrEqual(autopilot.frame.maxX, app.frame.maxX)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = large ? "Tonight-large" : "Tonight"
        attachment.lifetime = .keepAlways; add(attachment)
        autopilot.tap()
        XCTAssertTrue(app.navigationBars["Personal comfort"].waitForExistence(timeout: 10))
        app.navigationBars["Personal comfort"].buttons.element(boundBy: 0).tap()
        let alarm = app.buttons["tonight.alarm"]
        reveal(alarm, app: app); alarm.tap()
        XCTAssertTrue(app.navigationBars["Next alarm"].waitForExistence(timeout: 10))
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<20 {
            if element.exists, element.isHittable { return }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
}
