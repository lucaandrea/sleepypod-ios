import XCTest

@MainActor final class RemoteStageParityUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", "Dark", "-healthSyncEnabled", "NO", "-uiRoute", "sleep"]
        app.launch(); XCTAssertTrue(app.buttons["Sleep options"].waitForExistence(timeout: 15))
        app.buttons["Sleep options"].tap()
        let rules = app.buttons["sleep.openStageRules"]
        XCTAssertTrue(rules.waitForExistence(timeout: 5))
        rules.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Pod sleep stages"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start from preset"].waitForExistence(timeout: 8))
        show(app.buttons["Start from preset"], in: app)
        return app
    }
    private func show(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        for _ in 0..<35 {
            if element.isHittable { break }
            let scrollUp = element.exists && !element.frame.isEmpty ? element.frame.midY > app.frame.midY : up
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: scrollUp ? 0.70 : 0.35))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: scrollUp ? 0.35 : 0.70))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testRuleEditorAndPreviewSaveHistory() {
        let app = launch(); capture(app, "Stage-rules-top")
        app.buttons["Start from preset"].tap(); app.buttons["Movement only"].tap()
        let rule = app.descendants(matching: .any).matching(identifier: "stage.rule.0").firstMatch
        show(rule, in: app); rule.tap()
        let add = app.buttons["Add condition"].firstMatch; show(add, in: app); add.tap()
        XCTAssertTrue(app.textFields["Rule 1 condition 2 threshold"].waitForExistence(timeout: 4))
        capture(app, "Stage-rule-conditions")
        let remove = app.buttons["Remove condition"].firstMatch; show(remove, in: app); remove.tap()
        let save = app.buttons["stage.saveRules"]; show(save, in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        capture(app, "Stage-preview"); save.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save for '")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Updated stage rules"].waitForExistence(timeout: 8))
        let revert = app.buttons["Revert this change"].firstMatch; show(revert, in: app); capture(app, "Stage-history")
        revert.tap(); app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save for '")).firstMatch.tap()
        show(app.buttons["Start from preset"], in: app, up: false)
        XCTAssertTrue(app.staticTexts["System defaults"].exists)
    }
    func testUnsavedSideSwitchCanBeCancelledOrDiscarded() {
        let app = launch()
        app.buttons["Start from preset"].tap(); app.buttons["HRV first"].tap()
        let sides = app.segmentedControls.firstMatch
        show(sides, in: app, up: false)
        sides.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["Discard and switch"].waitForExistence(timeout: 3))
        capture(app, "Stage-unsaved-side")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap() }
        sides.buttons.element(boundBy: 1).tap(); app.buttons["Discard and switch"].tap()
        XCTAssertTrue(app.staticTexts["System defaults"].waitForExistence(timeout: 5))
        XCTAssertTrue(sides.buttons.element(boundBy: 1).isSelected)
    }
    func testModelLibraryReviewSelectionAndRulesFallback() {
        let app = launch()
        show(app.buttons["stage.openModels"], in: app, up: false)
        app.buttons["stage.openModels"].tap()
        XCTAssertTrue(app.navigationBars["Pod stage models"].waitForExistence(timeout: 4))
        let choice = app.buttons["stageModel.choice.1"]; XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        capture(app, "Stage-model-scorecard")
        let apply = app.buttons["stageModel.apply"]; show(apply, in: app); apply.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Use this model' AND identifier != 'stageModel.apply'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Model selected for this side. Rules remain the fallback."].waitForExistence(timeout: 5))
        let rules = app.buttons["stageModel.rulesOnly"]; show(rules, in: app, up: false); rules.tap()
        show(apply, in: app); apply.tap()
        app.buttons.matching(NSPredicate(format: "label == 'Use rules only' AND identifier != 'stageModel.apply'")).firstMatch.tap()
        let compare = app.buttons["Compare with rules"]; show(compare, in: app); compare.tap()
        XCTAssertTrue(app.staticTexts["0 nights scored"].waitForExistence(timeout: 5)); capture(app, "Stage-model-preview")
        XCTAssertFalse(app.buttons["Choose model JSON"].isEnabled)
    }
    func testNightStageSourceCanShowPodOrPhone() {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", "Light", "-healthSyncEnabled", "NO", "-uiRoute", "sleep"]
        app.launch()
        let source = app.segmentedControls["sleep.stageSource"]; XCTAssertTrue(source.waitForExistence(timeout: 15))
        show(source, in: app)
        source.buttons["Pod"].tap()
        XCTAssertTrue(app.staticTexts["Pod rules"].waitForExistence(timeout: 8)); show(app.staticTexts["Pod rules"], in: app); capture(app, "Stage-source-pod")
        show(source, in: app, up: false)
        source.buttons["This iPhone"].tap(); capture(app, "Stage-source-phone")
        XCTAssertTrue(source.buttons["This iPhone"].isSelected)
        source.buttons["Pod"].tap(); XCTAssertTrue(app.staticTexts["Pod rules"].waitForExistence(timeout: 8))
    }
}
