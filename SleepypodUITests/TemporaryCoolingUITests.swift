import XCTest

@MainActor final class TemporaryCoolingUITests: XCTestCase {
    func testReviewRequestCancelAndLostReply() { verify(large: false, lost: false); verify(large: false, lost: true) }
    func testReviewAtMaximumTextSize() { verify(large: true, lost: false) }
    private func launch(large: Bool, lost: Bool, delayed: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "temp",
                               "-household.personalWorkspaceActive", "NO", "-appearance", large ? "Light" : "Dark",
                               "-uiCoolingExample", "YES", "-uiCoolingLost", lost ? "YES" : "NO", "-uiCoolingDelayed", delayed ? "YES" : "NO",
                               "-temperatureFormat", "fahrenheit", "-temperatureLayout", "cards",
                               "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch(); XCTAssertTrue(app.buttons["Tonight"].firstMatch.waitForExistence(timeout: 30))
        return app
    }
    func testPendingOperations() {
        for large in [false, true] {
            let app = launch(large: large, lost: false, delayed: true)
            let preview = app.buttons["cooling.preview"]; reveal(preview, app); waitUntilEnabled(preview); preview.tap()
            let start = app.buttons["cooling.start"]; reveal(start, app); start.tap()
            let sending = app.staticTexts["cooling.progress"]
            XCTAssertTrue(sending.waitForExistence(timeout: 3)); XCTAssertEqual(sending.label, "Sending cooling request…"); capture("Cooling-sending-position-\(large)"); reveal(sending, app, requiresHit: false)
            XCTAssertTrue(app.staticTexts["cooling.review"].label.contains("68°F"))
            XCTAssertFalse(app.buttons["cooling.start"].exists)
            capture("Cooling-sending-\(large)")
            let cancel = app.buttons["cooling.cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 30)); reveal(cancel, app); waitUntilEnabled(cancel); cancel.tap()
            let cancelling = app.staticTexts["cooling.progress"]
            XCTAssertTrue(cancelling.waitForExistence(timeout: 3)); XCTAssertEqual(cancelling.label, "Requesting cancellation…"); reveal(cancelling, app, requiresHit: false)
            XCTAssertFalse(cancel.isEnabled); capture("Cooling-cancelling-\(large)")
            XCTAssertTrue(preview.waitForExistence(timeout: 30)); app.terminate()
        }
    }
    private func verify(large: Bool, lost: Bool) {
        let app = launch(large: large, lost: lost)
        let preview = app.buttons["cooling.preview"]; reveal(preview, app); waitUntilEnabled(preview); preview.tap()
        let review = app.staticTexts["cooling.review"]; reveal(review, app)
        XCTAssertTrue(review.label.contains("wake schedule is unchanged")); capture("Cooling-review-\(large)")
        let start = app.buttons["cooling.start"]; reveal(start, app)
        capture("Cooling-confirm-\(large)"); start.tap()
        let cancel = app.buttons["cooling.cancel"]; reveal(cancel, app)
        XCTAssertTrue(app.staticTexts["cooling.active"].exists); capture(lost ? "Cooling-unconfirmed" : "Cooling-active")
        if lost {
            let check = app.buttons["cooling.check"]; reveal(check, app); check.tap()
            XCTAssertFalse(app.buttons["cooling.start"].exists)
            XCTAssertTrue(app.staticTexts["cooling.notice"].label.contains("receipt"))
            reveal(cancel, app); cancel.tap()
            XCTAssertTrue(app.buttons["cooling.check"].waitForExistence(timeout: 5))
            XCTAssertFalse(cancel.isEnabled)
            capture("Cooling-cancel-unconfirmed")
        } else {
            cancel.tap(); reveal(preview, app); waitUntilEnabled(preview)
        }
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, requiresHit: Bool = true) {
        for _ in 0..<24 {
            let top = app.frame.height * 0.31, bottom = app.frame.height * 0.82
            if element.exists, !requiresHit || element.isHittable, element.frame.height > 0, element.frame.midY > top, element.frame.midY < bottom { return }
            let downward = element.exists && element.frame.midY < top
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.45 : 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.63 : 0.47))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reach \(element.identifier)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func waitUntilEnabled(_ element: XCUIElement) {
        // A refreshed report becomes current on the next one-second TimelineView tick.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }
}
