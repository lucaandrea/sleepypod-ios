import XCTest

@MainActor final class AutomationUITests: XCTestCase {
    private func launch(replay: Bool = false, appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "autopilot", "-uiAutomationReplay", replay ? "YES" : "NO"]
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
        show(app.descendants(matching: .any)["automation.combinedPlot"].firstMatch, app: app)
        capture(app, "Autopilot-combined-chart")
        show(app.staticTexts["Requested temperature · °F"], app: app)
        capture(app, "Autopilot-replay-chart")
    }
    func testNightTimelineInspectorAndRecentNightReplay() {
        let app = launch(appearance: "Light")
        let slider = app.sliders["automation.timelineSlider"]
        show(slider, app: app)
        let before = app.staticTexts["automation.timelineClock"].label
        slider.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertNotEqual(app.staticTexts["automation.timelineClock"].label, before)
        capture(app, "Autopilot-night-timeline")
        for _ in 0..<14 { if app.buttons["automation.edit.1"].isHittable { break }; app.swipeDown() }
        app.buttons["automation.edit.1"].tap()
        show(app.buttons["automation.range"], app: app); app.buttons["automation.range"].tap()
        XCTAssertTrue(app.navigationBars["Recent nights"].waitForExistence(timeout: 5))
        show(app.buttons["automation.runRange"], app: app); app.buttons["automation.runRange"].tap()
        show(app.staticTexts["automation.rangeSummary"], app: app)
        XCTAssertEqual(app.staticTexts["automation.rangeSummary"].label, "No replayable nights returned")
        capture(app, "Autopilot-recent-nights")
    }
    func testActivityMissingFilterShowsRecordedReasonWithoutSentEvents() {
        let app = launch(replay: true)
        app.buttons["Activity history"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic missing movement"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic dry run"].exists)
        app.buttons["automation.activityFilter"].tap()
        app.buttons["Missing"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic missing movement"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic dry run"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic sent event"].exists)
        capture(app, "Autopilot-filtered-activity")
    }
    func testRecordedZonesScrubAndPlayWithSyntheticProvenance() {
        let app = launch(replay: true)
        app.buttons["automation.edit.1"].tap()
        show(app.buttons["automation.backtest"], app: app); app.buttons["automation.backtest"].tap()
        XCTAssertTrue(app.buttons["Recorded pressure zones"].waitForExistence(timeout: 5)); app.buttons["Recorded pressure zones"].tap()
        XCTAssertTrue(app.buttons["automation.playZones"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic pressure-zone fixture · not your bed data"].exists)
        let slider = app.sliders["Replay frame"]; show(slider, app: app); slider.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertNotEqual(app.staticTexts["automation.zoneFrame"].label, "Frame 1 of 20")
        app.buttons["automation.playZones"].tap()
        XCTAssertEqual(app.buttons["automation.playZones"].label, "Pause replay")
        app.buttons["automation.playZones"].tap()
        XCTAssertEqual(app.buttons["automation.playZones"].label, "Play replay")
        // The native button crossfades its label; capture after that visual transition.
        Thread.sleep(forTimeInterval: 0.4)
        capture(app, "Autopilot-pressure-replay")
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
