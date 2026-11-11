import XCTest

@MainActor final class DaytimeContextUITests: XCTestCase {
    func testSeparateSourcesAndPriorWristContext() { verifyAvailable(large: false) }
    func testContextAtMaximumTextSize() { verifyAvailable(large: true) }
    func testOffEmptyAndUnavailableAreDistinct() {
        for scenario in ["off", "empty", "unavailable", "unreadable"] {
            let app = launch(scenario, large: false)
            XCTAssertFalse(app.buttons["context.refresh"].isEnabled)
            if scenario == "off" || scenario == "unreadable" {
                XCTAssertTrue(app.staticTexts["context.off"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["context.before"].exists)
                if scenario == "unreadable" {
                    reveal(app.staticTexts["context.message"], app)
                    XCTAssertTrue(app.staticTexts["context.message"].label.contains("local copy"))
                    capture("Context-unreadable-message")
                    reveal(app.buttons["context.remove"], app)
                    XCTAssertFalse(app.buttons["context.remove"].isEnabled)
                }
            } else {
                reveal(app.staticTexts["context.empty"], app)
                if scenario == "unavailable" { reveal(app.staticTexts["context.unavailable"], app) }
                else { XCTAssertFalse(app.staticTexts["context.unavailable"].exists) }
            }
            capture("Context-\(scenario)"); app.terminate()
        }
    }
    private func verifyAvailable(large: Bool) {
        let app = launch("available", large: large)
        let prefix = large ? "Context-large" : "Context"
        XCTAssertFalse(app.buttons["context.refresh"].isEnabled)
        XCTAssertGreaterThanOrEqual(app.buttons["context.refresh"].frame.height, 44)
        capture(prefix + "-overview")
        let window = app.buttons["context.before"]
        reveal(window, app)
        XCTAssertTrue(window.isEnabled)
        XCTAssertGreaterThanOrEqual(window.frame.height, 44)
        capture(prefix + "-window")
        window.tap()
        XCTAssertTrue(app.datePickers["context.time.picker"].waitForExistence(timeout: 5))
        capture(prefix + "-picker")
        app.buttons["context.time.done"].tap()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let workout = app.descendants(matching: .any).matching(identifier: "context.group.workout").firstMatch
        reveal(workout, app)
        XCTAssertTrue(workout.label.contains("Example Watch"))
        capture(prefix + "-activity")
        let wrist = app.descendants(matching: .any).matching(identifier: "context.wrist").firstMatch
        reveal(wrist, app)
        XCTAssertTrue(wrist.label.contains("34.2"))
        capture(prefix + "-wrist")
        reveal(app.buttons["context.remove"], app)
        XCTAssertFalse(app.buttons["context.access"].isEnabled)
        XCTAssertFalse(app.buttons["context.remove"].isEnabled)
        capture(prefix + "-privacy")
        app.terminate()
    }
    private func launch(_ scenario: String, large: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--daytime-context-fixture", "-apiBackend", "demo", "-onboardingComplete", "YES",
            "-healthSyncEnabled", "NO", "-household.personalWorkspaceActive", "NO", "-uiDaytimeContext", scenario,
            "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["Your day before bed"].waitForExistence(timeout: 10))
        return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<30 {
            let viewport = app.frame.insetBy(dx: 0, dy: 120)
            if element.exists, element.frame.height > 0, viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)), element.isHittable { return }
            if element.exists, element.frame.midY < viewport.minY { app.swipeDown() } else { app.swipeUp() }
        }
        print(app.debugDescription); capture("Context-unreachable"); XCTFail("Could not reach \(element)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
