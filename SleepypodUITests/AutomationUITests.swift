import XCTest

@MainActor final class AutomationUITests: XCTestCase {
    private func launch(replay: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", "Dark", "-healthSyncEnabled", "NO", "-uiRoute", "autopilot", "-uiAutomationReplay", replay ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["automation.new"].waitForExistence(timeout: 15))
        return app
    }
    func testNativeRuleCreationAndCompoundConditionNavigation() {
        let app = launch()
        capture(app, "Autopilot-rules")
        app.buttons["automation.edit.1"].tap()
        XCTAssertTrue(app.textFields["automation.name"].waitForExistence(timeout: 5))
        show(app.buttons["automation.conditions"], app: app); app.buttons["automation.conditions"].tap()
        XCTAssertTrue(app.navigationBars["Conditions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "21:00")).firstMatch.exists)
        capture(app, "Autopilot-compound-conditions")
        app.navigationBars["Conditions"].buttons.firstMatch.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["automation.new"].waitForExistence(timeout: 5))
        app.buttons["automation.new"].tap()
        XCTAssertTrue(app.textFields["automation.name"].waitForExistence(timeout: 5))
        let name = app.textFields["automation.name"]; name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "New automation".count) + "Native test rule")
        app.buttons["automation.save"].tap()
        XCTAssertTrue(app.buttons["automation.new"].waitForExistence(timeout: 5))
        show(app.staticTexts["Native test rule"], app: app)
        capture(app, "Autopilot-created-rule")
    }
    func testDiagnosticsAndBacktestEmptyStateRemainTruthful() {
        let app = launch()
        app.buttons["Diagnostics"].tap()
        XCTAssertTrue(app.staticTexts["Evaluations"].waitForExistence(timeout: 5))
        show(app.staticTexts["Missing signal"], app: app)
        capture(app, "Autopilot-diagnostics")
        app.buttons["Automations"].firstMatch.tap()
        app.buttons["automation.edit.1"].tap()
        show(app.buttons["automation.backtest"], app: app); app.buttons["automation.backtest"].tap()
        XCTAssertTrue(app.buttons["automation.runBacktest"].waitForExistence(timeout: 5))
        app.buttons["automation.runBacktest"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Demo has no recorded controller nights")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "Autopilot-backtest-no-history")
    }
    func testNestedTimeEditsPreserveBothChangesAndSaveToRule() {
        let app = launch()
        app.buttons["automation.edit.1"].tap()
        show(app.buttons["automation.conditions"], app: app); app.buttons["automation.conditions"].tap()
        app.buttons.containing(NSPredicate(format: "label == %@", "between 21:00 and 07:00")).firstMatch.tap()
        let start = app.textFields["automation.time.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        start.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "22:00")
        let end = app.textFields["automation.time.end"]; end.tap()
        end.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "08:00")
        app.navigationBars["Conditions"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["between 22:00 and 08:00"].exists)
        app.navigationBars["Conditions"].buttons.firstMatch.tap()
        app.buttons["automation.save"].tap()
        XCTAssertTrue(app.buttons["automation.new"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "between 22:00 and 08:00")).firstMatch.exists)
        capture(app, "Autopilot-edited-time")
    }
    func testCoreGeneratedSyntheticReplayChartsKeepProvenanceAndGaps() {
        let app = launch(replay: true)
        app.buttons["automation.edit.1"].tap()
        show(app.buttons["automation.backtest"], app: app); app.buttons["automation.backtest"].tap()
        XCTAssertTrue(app.buttons["automation.runBacktest"].waitForExistence(timeout: 5)); app.buttons["automation.runBacktest"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Chart validation fixture")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "Autopilot-replay-provenance")
        show(app.staticTexts["Requested temperature · °F"], app: app)
        capture(app, "Autopilot-replay-chart")
    }
    private func show(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<14 {
            if element.exists, element.isHittable, element.frame.midY < app.frame.maxY - 70, element.frame.midY > 130 { return }
            app.swipeUp()
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
