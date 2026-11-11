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
        XCTAssertTrue(open.waitForExistence(timeout: 30)); reveal(open, in: app)
        shot(app, name: large ? "Learning-large-entry" : "Learning-entry"); open.tap()
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
        for _ in 0..<35 {
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map(\.frame.maxY).max() ?? app.frame.minY
            let top = max(app.frame.minY + 120, navigationBottom + 12)
            let viewport = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: app.frame.maxY - 40 - top)
            if element.exists, element.frame.height > 0,
               viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)), element.isHittable { return }
            // A partially visible row under the navigation bar may still report itself as hittable.
            if element.exists, element.frame.midY < viewport.minY { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
        shot(app, name: "Learning-unreachable"); print(app.debugDescription)
        XCTFail("Could not reach learning control: \(element)")
    }
    private func shot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
