import XCTest

@MainActor final class IntelligenceModelsUITests: XCTestCase {
    func testLoadedResearchModelAndUntrainedBaselineAreDistinct() {
        let app = launch(large: false)
        reveal(app.staticTexts["Loaded and self-tested"], app: app)
        XCTAssertFalse(app.staticTexts["Not trained"].exists)
        capture(app, "Models-research-evidence")
        let anomaly = app.buttons["models.anomaly"]
        reveal(anomaly, app: app); anomaly.tap()
        XCTAssertTrue(app.navigationBars["Night baseline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Needs reviewed nights"].exists)
        XCTAssertFalse(app.buttons["anomaly.refresh"].isEnabled) // Demo never reads real Health.
        capture(app, "Models-baseline-readiness")
    }

    func testMaximumTextModelExplanationRemainsReadable() {
        let app = launch(large: true)
        for label in ["Your models, explained", "Sleep-stage research model", "Loaded and self-tested"] {
            let text = app.staticTexts[label]; reveal(text, app: app)
            XCTAssertGreaterThanOrEqual(text.frame.minX, 0)
            XCTAssertLessThanOrEqual(text.frame.maxX, app.frame.maxX)
        }
        capture(app, "Models-maximum-text")
    }

    private func launch(large: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-uiRoute", "models", "-appearance", "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let navigation = app.navigationBars["Intelligence models"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 15))
        if navigation.frame.minY > app.frame.height * 0.25 {
            navigation.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.12)))
        }
        return app
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<30 {
            if element.isHittable && element.frame.minY > 115 && element.frame.maxY < app.frame.maxY - 70 { return }
            let up = element.frame.minY < 115
            app.scrollViews.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.3 : 0.75)).press(forDuration: 0.1,
                thenDragTo: app.scrollViews.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.75 : 0.3)))
        }
        XCTFail("Unreachable \(element)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
