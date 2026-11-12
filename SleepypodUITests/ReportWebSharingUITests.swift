import XCTest

@MainActor final class ReportWebSharingUITests: XCTestCase {
    func testExplicitShareRefreshAndWithdrawal() { sharingFlow(large: false) }
    func testLargestTextKeepsConsentAndWithdrawalReadable() { sharingFlow(large: true) }

    func testLargestTextKeepsAnswerUpdateReadableAndRequiresConsent() {
        let app = launch("update", large: true)
        let status = app.staticTexts["report.share.status"]
        XCTAssertTrue(status.label.contains("New answers ready"))
        let send = app.buttons["report.share.send"]
        XCTAssertEqual(send.label, "Update shared answers"); XCTAssertFalse(send.isEnabled)
        reveal(send, app); capture("Answer-update-disabled-largest-text")
        consent(app); reveal(send, app); capture("Answer-update-consent-largest-text"); send.tap()
        reveal(status, app); XCTAssertTrue(status.label.contains("Shared with your Pod"))
        XCTAssertFalse(app.buttons["report.share.send"].exists)
        capture("Answer-update-shared-largest-text")
        app.terminate()
    }

    func testUncertainUploadRecoversThroughReadAndNeverOffersAnImmediateResend() {
        let app = launch("uncertain")
        consent(app)
        let send = app.buttons["report.share.send"]; reveal(send, app); send.tap()
        let status = app.staticTexts["report.share.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5)); reveal(status, app)
        XCTAssertTrue(status.label.contains("unconfirmed"))
        XCTAssertFalse(app.buttons["report.share.send"].exists)
        capture("Unconfirmed")
        let refresh = app.buttons["report.share.refresh"]; reveal(refresh, app); refresh.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5)); XCTAssertTrue(status.label.contains("Shared with your Pod"))
        XCTAssertFalse(app.buttons["report.share.send"].exists)
        capture("Recovered-by-read")
        app.terminate()
    }

    func testUnavailableControllerShowsRecoveryWithoutConsentOrSending() {
        let app = launch("offline")
        let message = app.staticTexts["report.share.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5)); reveal(message, app)
        XCTAssertTrue(message.label.contains("unavailable"))
        XCTAssertFalse(app.switches["report.share.consent"].exists)
        XCTAssertFalse(app.buttons["report.share.send"].exists)
        XCTAssertTrue(app.buttons["report.share.refresh"].isEnabled)
        capture("Unavailable")
        app.terminate()
    }

    private func sharingFlow(large: Bool) {
        let app = launch("ready", large: large)
        let suffix = large ? "-largest-text" : ""
        capture("Private" + suffix)
        XCTAssertFalse(app.buttons["report.share.send"].isEnabled)
        let privacy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "People with your Pod’s owner key")).firstMatch
        reveal(privacy, app); capture("Privacy" + suffix)
        consent(app)
        let send = app.buttons["report.share.send"]; reveal(send, app); XCTAssertTrue(send.isEnabled); capture("Consent" + suffix); send.tap()
        let status = app.staticTexts["report.share.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5)); reveal(status, app)
        XCTAssertTrue(status.label.contains("Shared with your Pod")); capture("Shared" + suffix)
        let result = app.staticTexts["report.share.message"]; reveal(result, app); capture("Shared-result" + suffix)
        let withdraw = app.buttons["report.share.withdraw"]; reveal(withdraw, app); capture("Withdraw-action" + suffix); withdraw.tap()
        let alert = app.alerts["Withdraw this shared copy?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); capture("Withdraw-confirmation" + suffix)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(withdraw.exists); withdraw.tap(); alert.buttons["Withdraw"].tap()
        reveal(status, app); XCTAssertTrue(status.label.contains("Web copy withdrawn"))
        XCTAssertFalse(app.buttons["report.share.send"].exists)
        let refresh = app.buttons["report.share.refresh"]; reveal(refresh, app); refresh.tap()
        XCTAssertTrue(status.label.contains("Web copy withdrawn")); capture("Withdrawn" + suffix)
        reveal(app.staticTexts["report.share.withdrawnDetails"], app); capture("Withdrawn-details" + suffix)
        app.terminate()
    }
    private func consent(_ app: XCUIApplication) {
        let row = app.switches["report.share.consent"]
        reveal(row, app)
        let control = row.switches.firstMatch.exists ? row.switches.firstMatch : row
        reveal(control, app)
        XCTAssertEqual(control.value as? String, "0", "Sharing must begin without consent")
        capture("Consent-before-tap")
        control.tap()
        // Wait for the binding's observable state; never retry a tap that could revoke consent.
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: control)
        let selection = XCTWaiter.wait(for: [selected], timeout: 5)
        capture("Consent-after-tap")
        XCTAssertEqual(selection, .completed, "The consent switch did not become selected")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["report.share.send"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["report.share.send"].isEnabled)
    }
    private func launch(_ scenario: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--report-sharing-fixture", "-apiBackend", "demo", "-onboardingComplete", "YES",
            "-healthSyncEnabled", "NO", "-household.personalWorkspaceActive", "NO", "-uiReportSharingScenario", scenario,
            "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Web copy"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["report.share.status"].waitForExistence(timeout: 5))
        return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<18 {
            let frame = element.frame
            if frame.minY >= app.frame.minY + 100 && frame.maxY <= app.frame.maxY - 65 && element.isHittable { return }
            let targetY = app.frame.minY + 115
            let distance = max(-250, min(250, targetY - frame.minY))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Report-sharing-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
