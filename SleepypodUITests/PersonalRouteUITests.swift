import XCTest

@MainActor final class PersonalRouteUITests: XCTestCase {
    func testExplicitEnrollmentAndDisableKeepAccountScreenReachable() {
        let app = launch()
        let verify = app.buttons["personalRoutes.verify"]
        XCTAssertFalse(verify.isEnabled)
        app.textFields["personalRoutes.away"].tap()
        app.textFields["personalRoutes.away"].typeText("https://away.preview.invalid\n")
        let reviewed = app.switches["personalRoutes.reviewed"]
        toggle(reviewed, app: app)
        XCTAssertTrue(verify.isEnabled)
        tap(verify, app: app)
        let enabled = app.switches["personalRoutes.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Personal-home-away-verified"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.swipeDown(); app.swipeDown()
        toggle(enabled, app: app)
        XCTAssertEqual(enabled.value as? String, "0")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 5))
        app.terminate()
    }
    func testOlderCoreExplainsMissingFreshnessWithoutEnablingFallback() {
        let app = launch(oldCore: true)
        app.textFields["personalRoutes.away"].tap()
        app.textFields["personalRoutes.away"].typeText("https://away.preview.invalid\n")
        toggle(app.switches["personalRoutes.reviewed"], app: app)
        XCTAssertTrue(app.buttons["personalRoutes.verify"].isEnabled)
        tap(app.buttons["personalRoutes.verify"], app: app)
        let message = app.staticTexts["personalRoutes.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Update Core"))
        XCTAssertFalse(app.switches["personalRoutes.enabled"].exists)
        app.terminate()
    }
    private func launch(oldCore: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--household-fixture", "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", "Dark"]
        if oldCore { app.launchArguments.append("--personal-route-old-core") }
        app.launch()
        let link = app.buttons["personalRoutes.accountLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 15)); tap(link, app: app)
        XCTAssertTrue(app.textFields["personalRoutes.home"].waitForExistence(timeout: 5))
        return app
    }
    private func tap(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable); element.tap()
    }
    private func toggle(_ row: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        let control = row.switches.firstMatch.exists ? row.switches.firstMatch : row
        XCTAssertTrue(control.isHittable); control.tap()
    }
}
