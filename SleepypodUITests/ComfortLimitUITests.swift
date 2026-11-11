import XCTest

@MainActor final class ComfortLimitUITests: XCTestCase {
    func testPracticeSeparatesComfortRangeAndWakeWarming() { verify(large: false) }
    func testLargeTextKeepsLimitEditorReachable() { verify(large: true) }
    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-household.personalWorkspaceActive", "NO", "-uiRoute", "", "-userDefaultSide", "left",
            "-temperatureLayout", "stage", "-appearance", large ? "Light" : "Dark",
            "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        let open = app.buttons["comfort.limit.open.left"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        reveal(open, in: app); open.tap()
        let edit = app.buttons["comfort.limit.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        reveal(edit, in: app); edit.tap()
        let toggle = app.switches["Enable automatic comfort range"]
        reveal(toggle, in: app)
        activate(toggle, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        let save = app.buttons["comfort.limit.save"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = large ? "Comfort-limit-large-text" : "Comfort-limit-editor"
        screenshot.lifetime = .keepAlways; add(screenshot)
        save.tap()
        let saved = app.staticTexts["68–72°F automatic range"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["comfort.limit.save"].exists)
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<20 where !element.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.isHittable)
    }
    private func activate(_ labeledSwitch: XCUIElement, in app: XCUIApplication) {
        // iOS 26 exposes a labeled row and a separate native switch. Target the
        // control itself instead of deriving a tap point from the label's frame.
        let row = labeledSwitch.frame
        let controls = app.switches.allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.width < row.width && row.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        XCTAssertLessThanOrEqual(controls.count, 1, "The comfort row must identify one native switch")
        if let control = controls.first {
            control.tap()
        } else {
            // Newer SwiftUI runtimes expose only the combined row.
            labeledSwitch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -24, dy: 0)).tap()
        }
    }
}
