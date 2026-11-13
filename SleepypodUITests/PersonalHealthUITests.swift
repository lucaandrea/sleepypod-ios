import XCTest

@MainActor final class PersonalHealthUITests: XCTestCase {
    func testConsentImportAndRemoval() { enrollment(large: false) }
    func testLargestTextConsentImportAndRemoval() { enrollment(large: true) }

    func testLargestTextSourceSelectionPreservesProvenance() {
        let app = launch("ready", large: true)
        let source = app.buttons["personalHealth.source"]
        let coverage = app.staticTexts["personalHealth.coverage"]
        reveal(source, app)
        XCTAssertEqual(source.value as? String, "Example Watch")
        capture("Source-short-largest")
        source.tap()
        let longName = "Example original sleep history imported from a previous bed"
        let option = app.buttons[longName].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5)); capture("Source-options-largest"); option.tap()
        reveal(source, app)
        XCTAssertEqual(source.value as? String, longName)
        capture("Source-long-largest")
        reveal(coverage, app)
        XCTAssertTrue(coverage.label.contains("2 recorded days")); XCTAssertTrue(coverage.label.contains(longName))
        capture("Source-long-coverage-largest")
        reveal(source, app); source.tap()
        let watch = app.buttons["Example Watch"].firstMatch
        XCTAssertTrue(watch.waitForExistence(timeout: 5)); watch.tap()
        reveal(coverage, app)
        XCTAssertTrue(coverage.label.contains("3 recorded days from Example Watch"))
        capture("Source-restored-largest"); app.terminate()
    }

    func testOfflineSavedCopyCannotRefresh() {
        let app = launch("offline")
        reveal(app.staticTexts["personalHealth.coverage"], app)
        XCTAssertTrue(app.staticTexts["personalHealth.coverage"].label.contains("3 recorded days"))
        reveal(app.buttons["personalHealth.refresh"], app)
        XCTAssertFalse(app.buttons["personalHealth.refresh"].isEnabled)
        capture("Offline"); app.terminate()
    }

    func testDifferentAccountAndUnreadableArchiveOfferNoImport() {
        for scenario in ["other", "storage"] {
            let app = launch(scenario)
            XCTAssertFalse(app.buttons["personalHealth.connect"].exists)
            XCTAssertFalse(app.buttons["personalHealth.refresh"].exists)
            capture(scenario); app.terminate()
        }
    }

    func testEmptyReadAndFailedRefreshKeepMeaningClear() {
        for scenario in ["empty", "failure"] {
            let app = launch(scenario)
            if scenario == "empty" { XCTAssertTrue(app.staticTexts["personalHealth.empty"].waitForExistence(timeout: 5)) }
            let refresh = app.buttons["personalHealth.refresh"]; reveal(refresh, app); refresh.tap()
            let message = app.staticTexts["personalHealth.message"]; reveal(message, app)
            XCTAssertTrue(message.label.contains(scenario == "empty" ? "no records or no permission" : "previous history is unchanged"))
            capture(scenario); app.terminate()
        }
    }

    func testLongImportCanBeCancelled() {
        let app = launch("slow")
        let refresh = app.buttons["personalHealth.refresh"]; reveal(refresh, app); refresh.tap()
        let progress = app.activityIndicators["personalHealth.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        capture("Importing")
        let cancel = app.buttons["Cancel import"]; reveal(cancel, app); cancel.tap()
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertFalse(progress.exists)
        XCTAssertTrue(app.staticTexts["personalHealth.message"].label.contains("Import cancelled"))
        XCTAssertTrue(app.staticTexts["personalHealth.coverage"].label.contains("3 recorded days"))
        capture("Cancelled"); app.terminate()
    }

    private func enrollment(large: Bool) {
        let app = launch("consent", large: large)
        let connect = app.buttons["personalHealth.connect"]
        if large { capture("Consent-top-largest") }
        reveal(connect, app); XCTAssertFalse(connect.isEnabled); capture(large ? "Consent-largest" : "Consent")
        let consent = app.switches["personalHealth.consent"]; reveal(consent, app)
        (consent.switches.firstMatch.exists ? consent.switches.firstMatch : consent).tap()
        reveal(connect, app); XCTAssertTrue(connect.isEnabled); connect.tap()
        XCTAssertTrue(app.staticTexts["personalHealth.linked"].waitForExistence(timeout: 5))
        if large {
            reveal(app.staticTexts["personalHealth.person"], app)
            app.swipeDown()
            capture("Imported-top-largest")
        }
        let coverage = app.staticTexts["personalHealth.coverage"]; reveal(coverage, app)
        XCTAssertTrue(coverage.label.contains("3 recorded days")); capture(large ? "Imported-largest" : "Imported")
        let automatic = app.switches["personalHealth.automatic"]; reveal(automatic, app)
        let automaticControl = automatic.switches.firstMatch.exists ? automatic.switches.firstMatch : automatic
        XCTAssertEqual(automatic.value as? String, "0")
        automaticControl.tap()
        XCTAssertEqual(automatic.value as? String, "1")
        automaticControl.tap()
        XCTAssertEqual(automatic.value as? String, "0")
        capture(large ? "Refresh-options-largest" : "Refresh-options")
        let remove = app.buttons["personalHealth.forget"]; reveal(remove, app); remove.tap()
        let alert = app.alerts["Remove this personal Health import?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3)); capture(large ? "Remove-largest" : "Remove")
        alert.buttons["Remove import"].tap()
        reveal(connect, app); XCTAssertFalse(connect.isEnabled); capture(large ? "Removed-largest" : "Removed")
        app.terminate()
    }
    private func launch(_ scenario: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--personal-health-fixture", "-apiBackend", "demo", "-onboardingComplete", "YES",
            "-healthSyncEnabled", "NO", "-household.personalWorkspaceActive", "NO", "-uiPersonalHealthScenario", scenario,
            "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Your Health history"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["personalHealth.person"].waitForExistence(timeout: 5))
        return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<18 {
            let frame = element.frame
            if frame.minY >= app.frame.minY + 100 && frame.maxY <= app.frame.maxY - 65 && element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
            let distance = max(-250, min(250, app.frame.minY + 115 - frame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Personal-health-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
