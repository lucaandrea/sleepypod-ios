import XCTest

@MainActor final class NightPhaseUITests: XCTestCase {
    private func launch(display: String = "degrees", scenario: String = "complete") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "", "-tempControl", "stepper", "-temperatureLayout", "cards", "-temperatureDisplay", display, "-uiContextScenario", scenario]
        app.launch(); XCTAssertTrue(app.buttons["Temp"].firstMatch.waitForExistence(timeout: 15)); return app
    }
    func testPhaseEditsReadBackInEveryDisplayMode() {
        for display in ["degrees", "offset", "eightSleep"] {
            let app = launch(display: display)
            let night = app.buttons["Night"].firstMatch; XCTAssertTrue(night.waitForExistence(timeout: 8)); night.tap()
            let warmer = app.buttons["Warmer night"]; XCTAssertTrue(warmer.waitForExistence(timeout: 5)); reveal(warmer, app); warmer.tap()
            let saved = app.staticTexts["Schedule saved"].firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 8)); reveal(saved, app)
            capture(app, "Night-saved-\(display)")
            let dawn = app.buttons["Dawn"].firstMatch; reveal(dawn, app); dawn.tap()
            let cooler = app.buttons["Cooler dawn"]; reveal(cooler, app); XCTAssertTrue(cooler.isEnabled)
            reveal(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "From ")).firstMatch, app)
            capture(app, "Dawn-\(display)"); app.terminate()
        }
    }
    func testEmptyScheduleOffersTemplateAndOfflineRetainsReadFailure() {
        var app = launch(scenario: "empty")
        app.buttons["Night"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Suggested · − / + saves it"].exists)
        capture(app, "Night-template")
        let warmer = app.buttons["Warmer night"]; reveal(warmer, app); warmer.tap()
        XCTAssertTrue(app.staticTexts["Schedule saved"].waitForExistence(timeout: 10) || app.otherElements["nightPhases.saved"].firstMatch.exists)
        reveal(app.staticTexts["Schedule saved"].firstMatch, app); capture(app, "Night-template-saved"); app.terminate()
        app = launch(scenario: "partial")
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Example controller is offline.")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 8)); reveal(error, app); capture(app, "Night-offline")
        XCTAssertFalse(app.buttons["Night"].firstMatch.isEnabled)
        XCTAssertTrue(app.buttons["nightPhases.reload"].exists)
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<30 {
            let scroll = app.scrollViews.firstMatch, bounds = app.scrollViews.firstMatch.frame.intersection(app.frame)
            let tabs = app.tabBars.firstMatch
            let bottom = tabs.exists ? min(bounds.maxY, tabs.frame.minY - 8) : bounds.maxY - 16
            let viewport = CGRect(x: bounds.minX, y: bounds.minY + 8, width: bounds.width, height: max(0, bottom - bounds.minY - 8))
            if element.exists, element.isHittable, viewport.contains(element.frame) { return }
            let delta = element.exists ? element.frame.midY - viewport.midY : viewport.height
            let distance = min(0.4, max(0.08, abs(delta) / max(bounds.height, 1))), direction = delta >= 0 ? 1.0 : -1.0
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
