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
        // SwiftUI exposes the full multiline label as the switch frame on iPad.
        // Tap the trailing thumb, then verify the requested value before saving.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -24, dy: 0)).tap()
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
}
