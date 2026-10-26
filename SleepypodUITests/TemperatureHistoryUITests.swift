import XCTest

@MainActor final class TemperatureHistoryUITests: XCTestCase {
    private func launch(scenario: String = "complete") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "", "-tempControl", "dial", "-temperatureLayout", "stage", "-temperatureDisplay", "degrees", "-uiContextScenario", scenario]
        app.launch(); XCTAssertTrue(app.buttons["Temp"].firstMatch.waitForExistence(timeout: 15)); return app
    }
    func testStagePreviewAndSharedHistoryWithRecordedAutopilot() {
        let app = launch()
        let preview = app.sliders["Preview tonight's schedule"]
        reveal(preview, app); preview.adjust(toNormalizedSliderPosition: 0.6)
        let live = app.buttons["Back to live"]
        XCTAssertTrue(live.waitForExistence(timeout: 5)); capture(app, "History-stage-preview")
        reveal(live, app, up: false); live.tap()
        let link = app.buttons["temperature.history.open"]
        reveal(link, app); capture(app, "History-stage-activity"); link.tap()
        XCTAssertTrue(app.navigationBars["Bed history"].waitForExistence(timeout: 5))
        capture(app, "History-overview")
        let slider = app.sliders["temperature.history.slider"]
        reveal(slider, app); slider.adjust(toNormalizedSliderPosition: 0.3)
        XCTAssertTrue(app.staticTexts["temperature.history.clock"].exists); capture(app, "History-inspected")
        let automation = app.buttons["Tonight’s Autopilot plan and recorded decisions"]
        reveal(automation, app); automation.tap()
        let timeline = app.sliders["automation.timelineSlider"]
        reveal(timeline, app); capture(app, "History-autopilot")
        XCTAssertTrue(timeline.isEnabled)
    }
    func testHistoryReadFailureDoesNotInventRecordedActivity() {
        let app = launch(scenario: "partial")
        let link = app.buttons["temperature.history.open"]
        reveal(link, app); link.tap()
        XCTAssertTrue(app.navigationBars["Bed history"].waitForExistence(timeout: 5))
        let error = app.staticTexts["Power history unavailable: Example controller is offline."].firstMatch
        reveal(error, app); capture(app, "History-offline")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Power coverage:'")).firstMatch.exists)
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, up: Bool = true) {
        for _ in 0..<30 {
            let scroll = app.scrollViews.firstMatch
            let bounds = scroll.frame.intersection(app.frame)
            let nav = app.navigationBars.firstMatch
            let tab = app.tabBars.firstMatch
            let top = nav.exists ? max(bounds.minY, nav.frame.maxY + 8) : bounds.minY
            let bottom = tab.exists ? min(bounds.maxY, tab.frame.minY - 8) : bounds.maxY - 12
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
            let frame = element.exists ? element.frame : .zero
            // A large-text card may exceed the viewport; its visible middle is still tappable.
            let visibleHeight = visible.intersection(frame).height
            if element.exists, element.isHittable,
               visible.contains(frame) || (frame.height > visible.height && visibleHeight >= visible.height * 0.85) { return }
            let delta = !frame.isEmpty ? frame.midY - visible.midY : (up ? visible.height : -visible.height)
            let distance = min(0.4, max(0.08, abs(delta) / max(bounds.height, 1)))
            let direction = delta >= 0 ? 1.0 : -1.0
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
