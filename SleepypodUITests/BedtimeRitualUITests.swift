import XCTest

@MainActor final class BedtimeRitualUITests: XCTestCase {
    func testTonightEntryOpensAndDismissesTheRealSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-uiRoute", "temp", "-household.personalWorkspaceActive", "NO", "-appearance", "Light", "-temperatureDisplay", "degrees"]
        app.launch(); XCTAssertTrue(app.buttons["Tonight"].firstMatch.waitForExistence(timeout: 20))
        tap("bedtime.open", app)
        XCTAssertTrue(app.navigationBars["Bedtime audio"].waitForExistence(timeout: 5))
        label("bedtime.connectionError", "Connect to your Pod", app)
        label("bedtime.connectionInstructions", "Settings → Pod connection", app)
        label("bedtime.manualStop", "tap Pause", app)
        XCTAssertFalse(app.buttons["bedtime.start"].exists); capture("Audio-real-sheet-unconnected")
        app.navigationBars["Bedtime audio"].buttons["Done"].tap()
        // Dismissal animates after Done; require the sheet to leave within a bounded wait.
        XCTAssertTrue(app.navigationBars["Bedtime audio"].waitForNonExistence(timeout: 5))
        reveal(app.buttons["bedtime.open"], app); app.terminate()
    }
    private func launch(_ mode: String = "ready", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bedtime-audio-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.navigationBars["Bedtime audio"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, towardTop: Bool = false) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > 110 && element.frame.midY < app.frame.maxY - 80 }
        for _ in 0..<24 {
            if visible() { break }
            let upward = element.exists ? element.frame.midY > app.frame.maxY - 80 : !towardTop
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: upward ? 0.77 : 0.30))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: upward ? 0.30 : 0.77)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func tap(_ name: String, _ app: XCUIApplication) { let button = app.buttons[name]; reveal(button, app); button.tap() }
    private func label(_ name: String, _ text: String, _ app: XCUIApplication, towardTop: Bool = true) {
        let value = app.staticTexts[name]; reveal(value, app, towardTop: towardTop)
        XCTAssertTrue(value.label.contains(text), value.label)
    }
    private func capture(_ name: String) {
        let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    func testSetupRequiresReviewAndDoesNotStartAudio() {
        let app = launch("setup"); capture("Audio-first-setup-light")
        tap("bedtime.setup", app)
        let save = app.buttons["bedtime.saveSetup"]; reveal(save, app); XCTAssertFalse(save.isEnabled)
        let reviewed = app.switches["bedtime.setupReviewed"]; reveal(reviewed, app)
        let toggle = reviewed.switches.firstMatch.exists ? reviewed.switches.firstMatch : reviewed
        toggle.tap(); reveal(save, app); XCTAssertTrue(save.isEnabled); capture("Audio-review-setup-light"); save.tap()
        XCTAssertTrue(app.navigationBars["Bedtime audio"].waitForExistence(timeout: 5))
        reveal(app.buttons["bedtime.start"], app); XCTAssertTrue(app.buttons["bedtime.start"].isEnabled)
        XCTAssertFalse(app.staticTexts["bedtime.result"].exists); capture("Audio-ready-light"); app.terminate()
    }
    func testCompletionObservationAndPauseStayDistinct() {
        let app = launch(); tap("bedtime.start", app)
        label("bedtime.result", "reported completion", app)
        label("bedtime.observation", "not been confirmed", app); capture("Audio-completed-unconfirmed-light")
        reveal(app.buttons["bedtime.start"], app); XCTAssertFalse(app.buttons["bedtime.start"].isEnabled)
        tap("bedtime.heard", app); label("bedtime.observation", "heard on selected", app)
        capture("Audio-heard-light"); tap("bedtime.pause", app)
        let confirm = app.buttons["Yes, run my Pause Shortcut"]; XCTAssertTrue(confirm.waitForExistence(timeout: 5)); capture("Audio-pause-review-light")
        confirm.tap(); label("bedtime.result", "reported completion", app)
        label("bedtime.resultDetail", "does not confirm it stopped", app)
        label("bedtime.observation", "Stopping the audio has not been confirmed", app)
        capture("Audio-pause-unconfirmed-light")
        tap("bedtime.stopped", app); label("bedtime.observation", "audio stopped", app)
        tap("bedtime.reviewed", app); reveal(app.buttons["bedtime.start"], app); XCTAssertTrue(app.buttons["bedtime.start"].isEnabled)
        capture("Audio-reviewed-stop-light"); app.terminate()
    }
    func testCustomSetupKeepsRoleLabelsAtLargestTextSize() {
        let app = launch("customSetup", large: true); tap("bedtime.edit", app)
        for (identifier, title, value) in [("startName", "Start Shortcut", "Nightfall A"),
                                          ("pauseName", "Pause Shortcut", "Quiet B"),
                                          ("speakers", "Speaker destination", "Guest room speakers")] {
            label("bedtime.\(identifier).label", title, app, towardTop: false)
            let field = app.textFields["bedtime.\(identifier)"]; reveal(field, app)
            XCTAssertEqual(field.value as? String, value)
            capture("Audio-custom-\(identifier)-dark-largest-text")
        }
        app.terminate()
    }
    func testAccountWithdrawalKeepsManualStopButNoPrivateSetup() {
        let app = launch("withdrawn"); tap("bedtime.start", app)
        label("bedtime.connectionError", "account changed", app)
        label("bedtime.manualStop", "does not stop external audio", app)
        XCTAssertFalse(app.buttons["bedtime.start"].exists)
        XCTAssertFalse(app.buttons["bedtime.edit"].exists)
        XCTAssertFalse(app.staticTexts["Bedside HomePods"].exists)
        capture("Audio-withdrawn-manual-stop-light"); app.terminate()
    }
    func testQuietAndUnavailableStatusDoNotOpenShortcuts() {
        for mode in ["quiet", "unavailable", "connectionError"] {
            let app = launch(mode)
            if mode == "connectionError" {
                label("bedtime.connectionError", "account changed", app); capture("Audio-connection-error-light")
                XCTAssertTrue(app.buttons["bedtime.retry"].isEnabled)
            } else {
                tap("bedtime.start", app)
                label("bedtime.error", mode == "quiet" ? "requested quiet" : "unavailable", app)
                XCTAssertFalse(app.staticTexts["bedtime.result"].exists); capture("Audio-\(mode)-light")
            }
            app.terminate()
        }
    }
    func testLostCallbackCanBeReviewedWithoutReplay() {
        let app = launch("pending"); tap("bedtime.start", app)
        label("bedtime.result", "Waiting for Shortcuts", app); capture("Audio-waiting-light")
        tap("bedtime.reviewed", app); label("bedtime.result", "Check Endel", app)
        capture("Audio-unknown-reviewed-light")
        reveal(app.buttons["bedtime.start"], app); XCTAssertTrue(app.buttons["bedtime.start"].isEnabled)
        app.terminate()
    }
    func testLargestTextKeepsRecoveryAndManualHelpUsable() {
        let app = launch("failed", large: true); reveal(app.buttons["bedtime.start"], app)
        XCTAssertGreaterThanOrEqual(app.buttons["bedtime.start"].frame.height, 44); capture("Audio-ready-dark-largest-text")
        tap("bedtime.start", app); label("bedtime.result", "reported a problem", app); capture("Audio-failed-dark-largest-text")
        tap("bedtime.notHeard", app); label("bedtime.observation", "no audio heard", app)
        tap("bedtime.reviewed", app); tap("bedtime.manualHelp", app)
        let recovery = app.staticTexts["To stop, pause in Endel. A phone call or another app can change what is playing."]
        reveal(recovery, app); capture("Audio-manual-dark-largest-text")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            reveal(recovery, app); capture("Audio-tablet-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        app.terminate()
    }
}
