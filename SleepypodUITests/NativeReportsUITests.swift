import XCTest
import UIKit

@MainActor final class NativeReportsUITests: XCTestCase {
    private func launch(_ route: String, empty: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-uiRoute", route,
            "-uiReportScenario", empty ? "empty" : "normal", "-intelligence.provider", "ollama", "-intelligence.localAddress", "http://127.0.0.1:11434",
            "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
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
