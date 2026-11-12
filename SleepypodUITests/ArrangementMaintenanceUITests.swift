import XCTest

@MainActor final class ArrangementMaintenanceUITests: XCTestCase {
    private func launch(_ mode: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--maintenance-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts[["activate", "activate-uncertain", "retry"].contains(mode) ? "household.assignment" : "maintenance.title"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 40 }
        for _ in 0..<32 {
            if visible() { break }
            let scrollUp = element.exists ? element.frame.midY > app.frame.maxY - 40 : !towardTop
            // Scroll through the label column rather than dragging across live switches.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: scrollUp ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: scrollUp ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func confirm(_ fields: [String], in app: XCUIApplication, firstAbove: Bool = false) {
        for (index, field) in fields.enumerated() {
            let toggle = app.switches["maintenance.confirm.\(field)"]; reveal(toggle, in: app, towardTop: index == 0 && firstAbove)
            XCTAssertEqual(toggle.value as? String, "0")
            // SwiftUI exposes both a full-width labelled row and its smaller native switch.
            let bounds = toggle.frame
            let controls = app.switches.matching(NSPredicate(format: "identifier == ''")).allElementsBoundByIndex
                .filter { bounds.contains($0.frame) && $0.isHittable }
            XCTAssertEqual(controls.count, 1, "Expected one native switch for \(field)")
            controls.first?.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, "Confirmation did not register: \(field)")
        }
        // Native lists recycle off-screen rows, particularly at accessibility text sizes.
        for (index, field) in fields.enumerated() {
            let toggle = app.switches["maintenance.confirm.\(field)"]
            reveal(toggle, in: app, towardTop: index == 0)
            XCTAssertEqual(toggle.value as? String, "1", "Confirmation changed while scrolling: \(field)")
        }
    }
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]; reveal(button, in: app); XCTAssertTrue(button.isEnabled); button.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testLaterApprovedReviewCanStartAfterCompletedCancellation() {
        let app = launch("retry", large: true)
        tap("arrangement.accountLink", in: app)
        tap("maintenance.reviewLink", in: app)
        let state = app.staticTexts["maintenance.state"]; reveal(state, in: app)
        capture(app, "Activation-previous-cancellation-kept")
        let start = app.buttons["maintenance.activate"]; reveal(start, in: app)
        XCTAssertFalse(start.isEnabled)
        confirm(["acknowledgeHeldUntilRecovery", "confirmClearTemporaryActions", "confirmEmptyAndAttended", "confirmPauseLearningAndSharedAutomations"], in: app, firstAbove: true)
        reveal(start, in: app)
        capture(app, "Activation-later-review-large-text")
        tap("maintenance.activate", in: app)
        // Entering maintenance replaces the navigation stack and starts the new form at its top.
        reveal(state, in: app)
        XCTAssertTrue(state.label.contains("recovery needed"))
        XCTAssertFalse(app.buttons["maintenance.activate"].exists)
        capture(app, "Activation-new-attempt-committed"); app.terminate()
    }
    func testUncertainActivationAndAbsentReceiptOnlyOfferReadRecovery() {
        let app = launch("activate-uncertain")
        tap("arrangement.accountLink", in: app)
        tap("maintenance.reviewLink", in: app)
        confirm(["acknowledgeHeldUntilRecovery", "confirmClearTemporaryActions", "confirmEmptyAndAttended", "confirmPauseLearningAndSharedAutomations"], in: app)
        tap("maintenance.activate", in: app)
        tap("maintenance.refresh", in: app)
        let message = app.staticTexts["maintenance.empty"]; reveal(message, in: app)
        XCTAssertTrue(message.label.contains("No saved receipt"))
        XCTAssertFalse(app.buttons["maintenance.activate"].exists)
        capture(app, "Activation-unknown-outcome-read-only"); app.terminate()
    }
    func testRestartRequiresAttendedConfirmationAndSavedReceiptPreventsRepeat() {
        let app = launch("restart")
        let restart = app.buttons["maintenance.restart"]; reveal(restart, in: app); XCTAssertFalse(restart.isEnabled)
        confirm(["acknowledgeConnectionWillClose", "acknowledgeControlsRemainPaused", "confirmEmptyAndAttended"], in: app)
        capture(app, "Maintenance-attended-restart"); tap("maintenance.restart", in: app)
        tap("maintenance.refresh", in: app)
        XCTAssertTrue(app.staticTexts["Waiting for a new controller session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["maintenance.restart"].exists)
        XCTAssertFalse(app.buttons["Comfort preferences"].exists)
        capture(app, "Maintenance-restart-saved-no-replay"); app.terminate()
    }
    func testRecoveryLargeTextExplicitlyReloadsAssignedAccount() {
        let app = launch("recover", large: true)
        confirm(["acknowledgeLearningRemainsOff", "acknowledgeRecordingGap", "confirmAssignedSides", "confirmEmptyAndAttended"], in: app)
        capture(app, "Maintenance-large-text-recovery"); tap("maintenance.recover", in: app)
        let state = app.staticTexts["maintenance.state"]; reveal(state, in: app)
        XCTAssertTrue(state.label.contains("Recovery recorded"))
        XCTAssertFalse(app.buttons["Comfort preferences"].exists)
        tap("maintenance.return", in: app)
        XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["household.assignment"].label, "Right side")
        capture(app, "Maintenance-new-assigned-account"); app.terminate()
    }
    func testKeepingSoloRequiresDigestReviewBeforeConfirmations() {
        let app = launch("held")
        XCTAssertFalse(app.buttons["maintenance.cancel"].exists)
        tap("maintenance.previewCancel", in: app)
        confirm(["acknowledgeSavedRoutinesMayResume", "confirmEmptyAndAttended", "confirmKeepSoloArrangement"], in: app)
        capture(app, "Maintenance-keep-solo-confirmation"); tap("maintenance.cancel", in: app)
        tap("maintenance.return", in: app)
        XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["household.assignment"].label.contains("Only sleeper")); app.terminate()
    }
    func testUnavailableStatusRetainsRetryAndSignOutWithoutOrdinaryEditors() {
        let app = launch("unavailable")
        XCTAssertTrue(app.staticTexts["maintenance.error"].waitForExistence(timeout: 5))
        tap("maintenance.refresh", in: app)
        XCTAssertFalse(app.buttons["Comfort preferences"].exists)
        XCTAssertFalse(app.buttons["Return to owner controls"].exists)
        tap("maintenance.signOut", in: app)
        XCTAssertFalse(app.staticTexts["maintenance.title"].exists); app.terminate()
    }
    func testApprovedReviewOpensSeparateActivationAndWithdrawsOldEditors() {
        let app = launch("activate")
        tap("arrangement.accountLink", in: app)
        XCTAssertTrue(app.navigationBars["Shared side review"].waitForExistence(timeout: 10))
        tap("maintenance.reviewLink", in: app)
        confirm(["acknowledgeHeldUntilRecovery", "confirmClearTemporaryActions", "confirmEmptyAndAttended", "confirmPauseLearningAndSharedAutomations"], in: app)
        capture(app, "Maintenance-approved-activation"); tap("maintenance.activate", in: app)
        let state = app.staticTexts["maintenance.state"]; reveal(state, in: app)
        XCTAssertTrue(state.label.contains("recovery needed"))
        XCTAssertFalse(app.buttons["Comfort preferences"].exists)
        XCTAssertFalse(app.buttons["maintenance.activate"].exists); app.terminate()
    }
    func testExistingRestartReceiptCannotOfferAnotherRestart() {
        let app = launch("unknown")
        XCTAssertFalse(app.buttons["maintenance.restart"].exists)
        tap("maintenance.refresh", in: app)
        XCTAssertFalse(app.buttons["maintenance.restart"].exists)
        capture(app, "Maintenance-existing-restart-receipt"); app.terminate()
    }
}
