import XCTest

@MainActor final class ArrangementMaintenanceUITests: XCTestCase {
    private func launch(_ mode: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--maintenance-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts[mode == "activate" ? "household.assignment" : "maintenance.title"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 40 }
        for _ in 0..<32 {
            if visible() { break }
            let up = !element.exists || element.frame.midY > app.frame.maxY - 40
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: up ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: up ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func confirm(_ fields: [String], in app: XCUIApplication) {
        for field in fields {
            let toggle = app.switches["maintenance.confirm.\(field)"]; reveal(toggle, in: app)
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]; reveal(button, in: app); XCTAssertTrue(button.isEnabled); button.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
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
