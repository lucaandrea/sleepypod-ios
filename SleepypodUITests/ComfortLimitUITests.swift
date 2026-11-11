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
        capture(large ? "Comfort-limit-large-before-toggle" : "Comfort-limit-before-toggle")
        activate(toggle, in: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        let toggled = XCTWaiter.wait(for: [enabled], timeout: 5)
        if toggled != .completed { capture("Comfort-limit-toggle-failure"); print(app.debugDescription) }
        XCTAssertEqual(toggled, .completed)
        let save = app.buttons["comfort.limit.save"]
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        capture(large ? "Comfort-limit-large-text" : "Comfort-limit-editor")
        save.tap()
        let saved = app.staticTexts["68–72°F automatic range"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["comfort.limit.save"].exists)
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = CGRect(x: app.frame.minX, y: app.frame.minY + 120, width: app.frame.width, height: app.frame.height - 240)
        for _ in 0..<30 {
            // A partly visible row can report hittable while its trailing control is under chrome.
            if element.exists, element.frame.height > 0, viewport.contains(element.frame), element.isHittable { return }
            let upward = !element.exists || element.frame.minY >= viewport.minY
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
            (upward ? lower : upper).press(forDuration: 0.05, thenDragTo: upward ? upper : lower, withVelocity: .slow, thenHoldForDuration: 0)
        }
        capture("Comfort-limit-unreachable"); print(app.debugDescription)
        XCTFail("Comfort control is not fully visible: \(element)")
    }
    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
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
