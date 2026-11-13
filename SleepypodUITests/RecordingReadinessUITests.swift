import XCTest

@MainActor final class RecordingReadinessUITests: XCTestCase {
    func testSleepShowsRecordingScopeAndReadOnlyChecks() { verify(large: false) }
    func testLargeTextKeepsChecksReachable() { verify(large: true) }

    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", "sleep", "-household.personalWorkspaceActive", "NO", "-appearance", large ? "Light" : "Dark",
                               "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["recording.readiness.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Recording checks are incomplete"), object: title)], timeout: 15), .completed)
        reveal(title, in: app)
        XCTAssertEqual(title.label, "Recording checks are incomplete")
        XCTAssertGreaterThanOrEqual(title.frame.minX, 0)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)
        let details = app.buttons["recording.readiness.details"]
        reveal(details, in: app)
        capture(large ? "Recording-large-closed" : "Recording-closed")
        // Some hosted runtimes return the diagnostics link as this button's activation point.
        // Tap the visible disclosure label, then retain the same expanded/content assertions.
        let disclosureLabel = details.staticTexts["See recording checks"]
        XCTAssertTrue(disclosureLabel.exists)
        print("Recording disclosure button: \(details.frame); label: \(disclosureLabel.frame)")
        disclosureLabel.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        expectExpanded(details, true)
        let storage = app.staticTexts["Recording storage"]
        reveal(storage, in: app)
        XCTAssertTrue(storage.isHittable)
        capture(large ? "Recording-large-text" : "Recording-checks")
        let refresh = app.buttons["recording.readiness.refresh"]
        reveal(refresh, in: app)
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 44)
        let checked = app.staticTexts["recording.readiness.checked"]
        let previousCheck = checked.label
        XCTAssertTrue(previousCheck.hasPrefix("Checked "))
        refresh.tap()
        // Waiting for idle alone can pass when no refresh happened. Require a new completed read.
        let finished = NSPredicate { _, _ in
            refresh.isEnabled && !refresh.label.contains("Checking") && checked.exists && checked.label != previousCheck
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: finished, evaluatedWith: refresh)], timeout: 10), .completed)
        expectExpanded(details, true)
        capture(large ? "Recording-large-refresh" : "Recording-refresh")
        // A fresh read must preserve the user's disclosure state, and one tap must close it.
        reveal(details, in: app)
        expectExpanded(details, true)
        details.staticTexts["Hide recording checks"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        expectExpanded(details, false)
        capture(large ? "Recording-large-reclosed" : "Recording-reclosed")
        XCTAssertFalse(app.buttons["Restart piezo processor"].exists)
    }
    private func expectExpanded(_ element: XCUIElement, _ expanded: Bool) {
        let state = NSPredicate(format: "value == %@", expanded ? "Expanded" : "Collapsed")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: state, evaluatedWith: element)], timeout: 5), .completed)
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // Check geometry before asking XCTest for a hit point on an offscreen element.
        for _ in 0..<32 {
            if element.exists {
                let frame = element.frame
                if frame.height > 0, frame.midY > 125, frame.midY < app.frame.maxY - 110 { return }
                if frame.midY <= 125 { app.swipeDown(velocity: .slow); continue }
            }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("Recording control could not be brought into view: \(element)")
    }
}
