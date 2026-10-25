import XCTest

@MainActor final class TemperatureContextUITests: XCTestCase {
    private func launch(layout: String = "cards", scenario: String = "complete") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", "Dark",
                               "-healthSyncEnabled", "NO", "-uiRoute", "", "-tempControl", "dial", "-temperatureLayout", layout,
                               "-temperatureDisplay", "eightSleep", "-uiContextScenario", scenario, "-userDefaultSide", "right"]
        app.launch()
        XCTAssertTrue(app.buttons["Temp"].firstMatch.waitForExistence(timeout: 15))
        return app
    }
    func testRoomAndRecentSleepOpenMatchingSideInSleepTab() {
        let app = launch()
        let room = app.staticTexts["temperature.room.title"]
        show(room, in: app)
        XCTAssertTrue(app.staticTexts["55%"].exists || app.otherElements["Humidity"].exists)
        capture(app, "Context-room")
        let recent = app.buttons["temperature.recentSleep"]
        show(recent, in: app)
        XCTAssertTrue(recent.label.contains("Right"))
        capture(app, "Context-recent-sleep")
        recent.tap()
        XCTAssertTrue(app.buttons["Sleep"].firstMatch.isSelected)
        XCTAssertTrue(app.navigationBars["Sleep"].waitForExistence(timeout: 5))
        capture(app, "Context-sleep-destination")
    }
    func testStaleStageReadingsAndPartialFailureStayExplicit() {
        let app = launch(layout: "stage", scenario: "stale")
        show(app.staticTexts["temperature.room.title"], in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "No fresh readings · last measured")).firstMatch.exists)
        capture(app, "Context-stale-stage")
        app.terminate()
        let partial = launch(scenario: "partial")
        show(partial.staticTexts["temperature.room.title"], in: partial)
        XCTAssertTrue(partial.staticTexts["Light unavailable: The light sensor is offline."].exists)
        show(partial.buttons["Reload room and sleep"], in: partial)
        XCTAssertTrue(partial.staticTexts["Vitals unavailable: The vitals service is offline."].exists)
        capture(partial, "Context-partial")
        partial.buttons["Reload room and sleep"].tap()
        XCTAssertTrue(partial.buttons["temperature.recentSleep"].exists)
    }
    private func show(_ element: XCUIElement, in app: XCUIApplication) {
        let topInset: CGFloat = app.frame.width > 600 ? 100 : 190
        let bottomInset: CGFloat = app.frame.width > 600 ? 20 : 110
        let viewport = CGRect(x: app.frame.minX, y: app.frame.minY + topInset, width: app.frame.width, height: app.frame.height - topInset - bottomInset)
        for _ in 0..<18 {
            let frame = element.frame
            if element.exists, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            // Scroll the margin; the centered dial and mattress intentionally own their drag gestures.
            let upward = !element.exists || frame.midY >= viewport.midY
            let surface = app.scrollViews.firstMatch
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: upward ? 0.78 : 0.30))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: upward ? 0.30 : 0.78))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
