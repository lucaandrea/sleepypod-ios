import XCTest

@MainActor final class PersonalAccountReportsUITests: XCTestCase {
    func testReportRequiresReviewedEvidenceAndFreshCloudConsent() {
        let app = launch("ready")
        capture("Empty-library")
        review(app)
        let evidence = app.buttons["personalReports.evidence"]; reveal(evidence, app); evidence.tap()
        capture("Calculated-evidence", settled: true)
        generate(app)
        let latest = app.buttons["personalReports.latest"]; reveal(latest, app); latest.tap()
        XCTAssertTrue(app.navigationBars["Your morning brief"].waitForExistence(timeout: 5))
        let coverage = app.staticTexts["12/14 days"]; reveal(coverage, app)
        XCTAssertFalse(app.staticTexts["Missing data"].exists)
        capture("Saved-brief")
        let chart = app.descendants(matching: .any).matching(identifier: "brief.chart").firstMatch
        reveal(chart, app); capture("Comparison-calendar", settled: true)
        let full = app.buttons["personalReports.fullReport"]; reveal(full, app); full.tap()
        reveal(app.staticTexts["Your recent pattern"].firstMatch, app)
        capture("Rendered-interpretation", settled: true)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "###")).firstMatch.exists)
        app.terminate()
    }

    func testLargestTextFollowUpAndPersonalWebCopy() {
        let app = launch("saved", large: true)
        capture("Saved-largest-top")
        let latest = app.buttons["personalReports.latest"]; reveal(latest, app); latest.tap()
        let field = app.textFields["Your question"].exists ? app.textFields["Your question"] : app.textViews["Your question"]
        reveal(field, app); field.tap(); field.typeText("What should I compare next?")
        app.toolbars.buttons["Done"].firstMatch.tapIfPresent()
        let review = app.buttons["personalReports.reviewAnswer"]; reveal(review, app); review.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture("Follow-up-review-largest")
        generate(app)
        let message = app.staticTexts["personalReports.message"]; reveal(message, app)
        XCTAssertTrue(message.label.contains("original evidence")); capture("Follow-up-saved-largest")
        let provenance = app.staticTexts["personalReports.answerProvenance"].firstMatch; reveal(provenance, app)
        XCTAssertEqual(provenance.label, "AI interpretation"); capture("Follow-up-provenance-largest", settled: true)
        let web = app.buttons["personalReports.webCopy"]; reveal(web, app); web.tap()
        let privacy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This copy belongs to your personal account")).firstMatch
        reveal(privacy, app); capture("Web-copy-privacy-largest")
        let consent = app.switches["report.share.consent"]; reveal(consent, app)
        let control = consent.switches.firstMatch.exists ? consent.switches.firstMatch : consent
        XCTAssertEqual(control.value as? String, "0"); control.tap()
        let share = app.buttons["report.share.send"]; reveal(share, app); XCTAssertTrue(share.isEnabled); share.tap()
        let status = app.staticTexts["report.share.status"]; reveal(status, app)
        XCTAssertTrue(status.label.contains("Shared with your Pod")); capture("Web-copy-shared-largest")
        app.terminate()
    }

    func testOfflineMissingHealthAndUnreadableStorageHaveNoCreateAction() {
        for scenario in ["offline", "empty", "storage"] {
            let app = launch(scenario)
            let review = app.buttons["personalReports.review"]
            if scenario == "storage" { XCTAssertFalse(review.exists) }
            else {
                reveal(review, app); XCTAssertFalse(review.isEnabled)
                if scenario == "offline" { reveal(app.staticTexts["personalReports.offline"], app) }
                else { reveal(app.staticTexts["personalReports.needsHealth"], app) }
            }
            capture(scenario); app.terminate()
        }
    }

    func testOwnModelSettingsAndDiagnosticContainNoHealthRequest() {
        let app = launch("ready")
        let settings = app.buttons["personalReports.models"]; reveal(settings, app); settings.tap()
        XCTAssertTrue(app.navigationBars["Your model"].waitForExistence(timeout: 5)); capture("Own-model-settings")
        let model = app.textFields["personalReports.modelID"]; reveal(model, app); model.tap()
        model.typeText("-reviewed")
        app.toolbars.buttons["Done"].firstMatch.tapIfPresent()
        let save = app.buttons["personalReports.saveModel"]; reveal(save, app); XCTAssertTrue(save.isEnabled); save.tap()
        let test = app.buttons["personalReports.testModel"]; reveal(test, app); test.tap()
        let response = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No Health or Pod evidence was sent.")).firstMatch
        reveal(response, app); capture("Own-model-tested")
        app.terminate()
    }

    func testRequestFailureAndCancellationNeverProduceAReport() {
        for scenario in ["error", "slow"] {
            let app = launch(scenario)
            review(app); consent(app)
            let generate = app.buttons["personalReports.generate"]; reveal(generate, app); generate.tap()
            if scenario == "slow" {
                let cancel = app.buttons["personalReports.cancel"]; reveal(cancel, app); capture("Request-running"); cancel.tap()
            }
            let message = app.staticTexts["personalReports.message"]; reveal(message, app)
            XCTAssertTrue(message.label.contains(scenario == "error" ? "No automatic retry" : "cancelled"))
            XCTAssertFalse(app.buttons["personalReports.latest"].exists)
            capture(scenario); app.terminate()
        }
    }

    func testRemovalNeedsConfirmationAndKeepsModelSettings() {
        let app = launch("saved")
        let remove = app.buttons["personalReports.remove"]; reveal(remove, app); remove.tap()
        let alert = app.alerts["Remove these personal reports?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); capture("Removal-confirmation")
        alert.buttons["Cancel"].tap(); XCTAssertTrue(app.buttons["personalReports.latest"].exists)
        reveal(remove, app); remove.tap(); alert.buttons["Remove reports"].tap()
        XCTAssertFalse(app.buttons["personalReports.latest"].exists)
        let settings = app.buttons["personalReports.models"]; reveal(settings, app); capture("Reports-removed")
        settings.tap(); XCTAssertTrue(app.textFields["personalReports.modelID"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["personalReports.modelID"].value as? String, "example-model")
        app.terminate()
    }

    private func review(_ app: XCUIApplication) {
        let button = app.buttons["personalReports.review"]; reveal(button, app); XCTAssertTrue(button.isEnabled); button.tap()
        reveal(app.staticTexts["personalReports.destination"], app); capture("Request-review")
        XCTAssertFalse(app.buttons["personalReports.generate"].isEnabled)
    }
    private func consent(_ app: XCUIApplication) {
        let row = app.switches["personalReports.consent"]; reveal(row, app)
        let control = row.switches.firstMatch.exists ? row.switches.firstMatch : row
        XCTAssertEqual(control.value as? String, "0"); control.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["personalReports.generate"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    }
    private func generate(_ app: XCUIApplication) {
        consent(app)
        let button = app.buttons["personalReports.generate"]; reveal(button, app); capture("Consented-request"); button.tap()
        let message = app.staticTexts["personalReports.message"]; reveal(message, app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] %@", "saved"), object: message)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
    }
    private func launch(_ scenario: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--personal-reports-fixture", "-apiBackend", "demo", "-onboardingComplete", "YES",
            "-healthSyncEnabled", "NO", "-household.personalWorkspaceActive", "NO", "-uiPersonalReportScenario", scenario,
            "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.navigationBars["Your personal reports"].waitForExistence(timeout: 15))
        return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        // SwiftUI Forms create off-screen rows lazily; scroll before asserting discovery.
        for attempt in 0..<24 {
            let exists = element.waitForExistence(timeout: 0.3)
            let frame = exists ? element.frame : .zero
            let top = app.frame.minY + 100
            let bottom = app.frame.maxY - 36
            let visibleHeight = frame.height > bottom - top ? 80 : frame.height
            if exists && frame.height > 0 && frame.minY >= top && frame.minY + visibleHeight <= bottom && element.isHittable {
                XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
                return
            }
            let distance = exists && frame.height > 0
                ? max(-300, min(300, top + 15 - frame.minY))
                : (attempt < 16 ? -300.0 : 300.0)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ name: String, settled: Bool = false) {
        var screenshot = XCUIScreen.main.screenshot()
        if settled {
            // XCTest can become idle before SwiftUI disclosure rendering finishes.
            // Require two unchanged rendered frames, not just the final accessibility frame.
            var stableSamples = 0
            let deadline = Date().addingTimeInterval(8)
            while stableSamples < 2 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.4)
                let next = XCUIScreen.main.screenshot()
                stableSamples = next.pngRepresentation == screenshot.pngRepresentation ? stableSamples + 1 : 0
                screenshot = next
            }
            XCTAssertEqual(stableSamples, 2, "Disclosure did not reach a stable rendered state")
        }
        let item = XCTAttachment(screenshot: screenshot)
        item.name = "Personal-report-" + name; item.lifetime = .keepAlways; add(item)
    }
}

private extension XCUIElement {
    func tapIfPresent() { if exists && isHittable { tap() } }
}
