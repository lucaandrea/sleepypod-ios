import XCTest

@MainActor final class BiometricProfilesUITests: XCTestCase {
    func testCandidateReviewActivationAndHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap("settings.biometricProfiles", app)
        XCTAssertTrue(app.navigationBars["Biometric calibration"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Profile and processor"].waitForExistence(timeout: 5))
        capture(app, "Profiles-overview")
        tap("profiles.library", app); tap("profiles.new", app)
        let parameter = app.textFields["candidate.number.heart_rate.trackingToleranceBpm"]
        reveal(parameter, app); parameter.tap(); parameter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "18\n")
        capture(app, "Profiles-numeric-draft")
        tap("candidate.stages", app)
        tap("candidate.fallback", app)
        let fallback = app.buttons["candidate.fallback.option.Wake"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 3)); fallback.tap()
        capture(app, "Profiles-stage-draft")
        for title in ["From", "To", "Via"] {
            let control = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "candidate.transition.", ".\(title)")).firstMatch
            reveal(control, app); XCTAssertEqual(control.label, title)
        }
        capture(app, "Profiles-transitions")
        app.navigationBars.buttons.firstMatch.tap()
        tap("candidate.review", app)
        XCTAssertTrue(app.staticTexts["Schema checks passed"].waitForExistence(timeout: 5))
        capture(app, "Profiles-candidate-review")
        reveal(app.buttons["candidate.save"], app); capture(app, "Profiles-save-action")
        tap("candidate.save", app)
        XCTAssertTrue(app.staticTexts["Candidate saved"].waitForExistence(timeout: 5))
        tap("candidate.inspectSaved", app)
        XCTAssertTrue(app.staticTexts["Reviewed configuration"].waitForExistence(timeout: 5))
        capture(app, "Profiles-configuration-diff")
        let acknowledgement = app.switches["profiles.acknowledge"]
        reveal(acknowledgement, app); acknowledgement.tap()
        reveal(app.buttons["profiles.apply"], app); capture(app, "Profiles-apply-action")
        tap("profiles.apply", app)
        tap("profiles.lastReceipt", app)
        XCTAssertTrue(app.staticTexts["Waiting for delivery"].waitForExistence(timeout: 5))
        capture(app, "Profiles-pending-processor")
        for _ in 0..<6 where !app.navigationBars["Biometric calibration"].exists { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(app.navigationBars["Biometric calibration"].exists)
        tap("profiles.history", app)
        XCTAssertTrue(app.staticTexts["Activate · generation 1"].waitForExistence(timeout: 5))
        capture(app, "Profiles-history")
        app.navigationBars.buttons.firstMatch.tap()
        tap("profiles.rollback", app)
        XCTAssertTrue(app.staticTexts["Reviewed configuration"].waitForExistence(timeout: 5))
        capture(app, "Profiles-recovery-review")
    }
    private func tap(_ identifier: String, _ app: XCUIApplication) {
        let button = app.buttons[identifier]; reveal(button, app); XCTAssertTrue(button.isEnabled); button.tap()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<65 {
            let names = ["profiles.content", "profiles.libraryContent", "candidate.content", "candidate.stageContent", "profiles.reviewContent", "profiles.receiptContent", "profiles.historyContent"]
            let surface = names.map { app.scrollViews[$0] }.first { $0.exists && $0.isHittable } ?? app
            let bounds = surface.frame.intersection(app.frame), nav = app.navigationBars.firstMatch
            let top = nav.exists ? max(bounds.minY, nav.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 10))
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = !(element.exists && element.frame.midY < visible.minY)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.75 : 0.35)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.35 : 0.75)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
