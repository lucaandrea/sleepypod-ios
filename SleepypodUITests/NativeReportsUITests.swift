import XCTest
import UIKit

@MainActor final class NativeReportsUITests: XCTestCase {
    private func launch(_ route: String, empty: Bool = false, saved: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-uiRoute", route,
            "-uiReportScenario", saved ? "saved" : empty ? "empty" : "normal", "-intelligence.provider", "ollama", "-intelligence.localAddress", "http://127.0.0.1:11434",
            "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let navigation = app.navigationBars[route == "coach" ? "Sleep coach" : "Personal reports"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 15))
        if navigation.frame.minY >= app.frame.height * 0.25 {
            navigation.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.12)))
        }
        return app
    }
    func testLocalCoachRangesAndMissingEvidence() {
        let app = launch("coach")
        capture(app, "Reports-coach")
        choose("7 days", picker: "History range", app: app)
        capture(app, "Reports-seven-days")
        let explore = app.buttons["reports.explore"]; reveal(explore, app)
        XCTAssertTrue(explore.isEnabled); explore.tap()
        let observation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[pod.presence]")).firstMatch
        reveal(observation, app, partial: true); XCTAssertTrue(observation.label.contains("not establish sleep stages")); capture(app, "Reports-local-observations")
        app.terminate()
        let empty = launch("coach", empty: true), disabled = empty.buttons["reports.explore"]
        reveal(disabled, empty); XCTAssertFalse(disabled.isEnabled); capture(empty, "Reports-empty")
    }
    func testEvidenceReviewConsentResetAndDemoDoesNotSend() {
        let app = launch("reports"), include = app.switches["reports.includePod"]
        reveal(include, app); if include.value as? String != "1" { include.tap() }
        let disclosure = app.buttons["reports.evidence"]
        reveal(disclosure, app); disclosure.tap(); capture(app, "Reports-reviewed-evidence")
        let consent = app.switches["reports.consent"]
        reveal(consent, app); consent.tap(); XCTAssertEqual(consent.value as? String, "1")
        let generate = app.buttons["reports.generate"]; reveal(generate, app)
        XCTAssertFalse(generate.isEnabled); capture(app, "Reports-demo-model")
        reveal(include, app); include.tap()
        reveal(consent, app); XCTAssertEqual(consent.value as? String, "0"); capture(app, "Reports-consent-reset")
    }
    func testSavedReportRendersHeadingsAndTraceableEvidence() {
        let app = launch("reports", saved: true)
        let heading = app.staticTexts["Your recent pattern"]
        reveal(heading, app); capture(app, "Saved-report-rendered")
        XCTAssertFalse(app.staticTexts["### Your recent pattern"].exists)
        let source = app.buttons["report.source.health.recent"].firstMatch
        reveal(source, app); source.tap()
        let evidence = app.staticTexts["report.evidence.health.recent"]
        reveal(evidence, app)
        XCTAssertEqual(evidence.label, "Three recorded days in seven. Missing days remain unknown, not zero sleep.")
        capture(app, "Saved-report-source")
        let original = app.buttons["report.original"]
        reveal(original, app); original.tap()
        let raw = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "### Your recent pattern")).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        capture(app, "Saved-report-original-preserved")
    }
    func testMaximumTextReportAndEvidenceFitScreen() {
        let app = launch("reports", saved: true, large: true)
        for title in ["Your recent pattern", "What the evidence can tell us", "One optional experiment", "Uncertainty"] {
            let heading = app.staticTexts[title]
            reveal(heading, app, partial: true)
            XCTAssertGreaterThanOrEqual(heading.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(heading.frame.maxX, app.frame.maxX)
            capture(app, "Saved-report-large-" + title)
        }
        let source = app.buttons["report.source.health.hrv"].firstMatch
        reveal(source, app); source.tap()
        let evidence = app.staticTexts["report.evidence.health.hrv"]
        reveal(evidence, app)
        XCTAssertEqual(evidence.label, "Daily HRV uses SDNN; it is not the Pod’s window variability metric.")
        XCTAssertGreaterThanOrEqual(evidence.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(evidence.frame.maxX, app.frame.maxX)
        capture(app, "Saved-report-large-evidence")
    }
    func testRecoveryShowsSavedAddressAndRetryWithoutChangingKeys() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--connection-fixture", "--demo", "-apiBackend", "demo", "-podURL", "https://connection-preview.invalid",
                               "-podIPAddress", "192.0.2.99", "-appearance", "Light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let title = app.staticTexts["connection.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let rejected = NSPredicate(format: "label == %@", "Connection needs attention")
        expectation(for: rejected, evaluatedWith: title); waitForExpectations(timeout: 10)
        reveal(title, app, partial: true); capture(app, "Connection-access-rejected")
        let address = app.staticTexts["connection.savedAddress"]
        reveal(address, app, partial: true)
        XCTAssertEqual(address.label, "https://connection-preview.invalid")
        let retry = app.buttons["connection.retry"]
        reveal(retry, app); XCTAssertTrue(retry.isEnabled); retry.tap()
        let settings = app.buttons["connection.settings"]
        reveal(settings, app); capture(app, "Connection-recovery-actions")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Pod connection"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Pod controller address"].value as? String, "https://connection-preview.invalid")
    }
    private func choose(_ title: String, picker: String, app: XCUIApplication) {
        let button = app.buttons[title]
        if button.exists { reveal(button, app); button.tap(); return }
        let menu = app.buttons["reports.range"].firstMatch
        reveal(menu, app); menu.tap(); app.buttons[title].tap()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, partial: Bool = false) {
        guard element.waitForExistence(timeout: 5) else { XCTFail("Missing control: \(element)"); return }
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<45 {
            if element.exists && element.isHittable && element.frame.minY > 115 && (partial ? element.frame.minY < scroll.frame.maxY - 80 : element.frame.maxY < scroll.frame.maxY - 8) { return }
            let up = element.exists && element.frame.midY < 115
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.3 : 0.73)).press(forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.73 : 0.3)))
        }
        XCTFail("Unreachable \(element), frame \(element.frame)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
