import XCTest

@MainActor final class LearningJourneyUITests: XCTestCase {
    func testJourneyKeepsThreePurposesAndReviewActionsSeparate() { verify(large: false) }
    func testJourneySupportsLargeTextAndIndependentTemperatureSide() { verify(large: true) }

    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-uiRoute", "sleep", "-household.personalWorkspaceActive", "NO", "-userDefaultSide", "left", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let open = app.buttons["learning.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 30)); reveal(open, in: app); open.tap()
        let side = app.segmentedControls["learning.side"]
        XCTAssertTrue(side.waitForExistence(timeout: 10)); reveal(side, in: app); side.buttons["Right"].tap()
        let stage = app.buttons["learning.stages"]
        reveal(stage, in: app)
        XCTAssertTrue(stage.label.contains("Left"))
        XCTAssertLessThanOrEqual(stage.frame.maxX, app.frame.maxX)
        shot(app, name: large ? "Learning-large-stages" : "Learning-stages")
        let baseline = app.buttons["learning.baseline"]
        reveal(baseline, in: app); XCTAssertTrue(baseline.isEnabled)
        let thermal = app.buttons["learning.temperature"]
        reveal(thermal, in: app)
        shot(app, name: large ? "Learning-large-temperature" : "Learning-temperature")
        let refresh = app.buttons["learning.refresh"]
        reveal(refresh, in: app)
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 44)
        XCTAssertLessThanOrEqual(refresh.frame.maxX, app.frame.maxX)
        shot(app, name: large ? "Learning-large-refresh" : "Learning-refresh")
        app.swipeDown(velocity: .slow)
        reveal(thermal, in: app)
        thermal.tap()
        let comfortSide = app.segmentedControls["comfort.side"]
        XCTAssertTrue(comfortSide.waitForExistence(timeout: 10))
        XCTAssertTrue(comfortSide.buttons["Right"].isSelected)
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<35 where !element.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.isHittable)
    }
    private func shot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
