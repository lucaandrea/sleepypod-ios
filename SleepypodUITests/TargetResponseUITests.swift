import XCTest
import UIKit

@MainActor final class TargetResponseUITests: XCTestCase {
    func testExplicitFitAndConditionalPreview() { verifyFlow(large: false) }
    func testLargeTextAndCelsiusPreview() { verifyFlow(large: true) }
    func testNormalLightPracticeAndErrorText() {
        for mode in ["ready", "unavailable"] {
            let app = open(mode: mode, large: false, light: true)
            let refresh = app.buttons["response.refresh"]; reveal(refresh, app); refresh.tap()
            let result = app.staticTexts[mode == "unavailable" ? "response.error" : "response.state"]
            XCTAssertTrue(result.waitForExistence(timeout: 10)); reveal(result, app)
            capture("Response-light-\(mode)"); app.terminate()
        }
    }
    func testMissingAndFailedEvidenceKeepsControlUnavailable() {
        for (mode, expected) in [("empty", "Collecting evidence"), ("failed", "Not reliable yet"), ("changed", "Needs recheck"), ("unavailable", "Response evidence could not be checked")] {
            let app = open(mode: mode, large: false)
            let refresh = app.buttons["response.refresh"]; reveal(refresh, app); refresh.tap()
            let result = app.staticTexts[mode == "unavailable" ? "response.error" : "response.state"]
            XCTAssertTrue(result.waitForExistence(timeout: 10)); reveal(result, app)
            XCTAssertTrue(result.label.contains(expected))
            XCTAssertFalse(app.buttons["response.preview"].exists)
            if mode != "changed" { XCTAssertFalse(app.buttons["response.fit"].exists) }
            capture("Response-\(mode)"); app.terminate()
        }
    }
    private func verifyFlow(large: Bool) {
        let app = open(mode: "ready", large: large)
        XCTAssertFalse(app.buttons["response.fit"].exists)
        let refresh = app.buttons["response.refresh"]; reveal(refresh, app); refresh.tap()
        let state = app.staticTexts["response.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10)); XCTAssertEqual(state.label, "Ready to evaluate")
        capture(large ? "Response-large-ready" : "Response-ready")
        let fit = app.buttons["response.fit"]; reveal(fit, app)
        XCTAssertGreaterThanOrEqual(fit.frame.height, 44)
        XCTAssertEqual(fit.label, "Evaluate response model")
        capture(large ? "Response-large-fit" : "Response-fit"); fit.tap()
        XCTAssertTrue(app.staticTexts["response.state"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["response.state"].label, "Research preview")
        let comparison = app.buttons["response.comparison"]; reveal(comparison, app); comparison.tap()
        let thirty = app.staticTexts["30 minutes · Passed comparison"]; reveal(thirty, app)
        capture(large ? "Response-large-evaluation" : "Response-evaluation")
        let preview = app.buttons["response.preview"]; reveal(preview, app)
        XCTAssertGreaterThanOrEqual(preview.frame.height, 44); preview.tap()
        let candidate = app.staticTexts["response.target.69"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10)); reveal(candidate, app)
        XCTAssertTrue(candidate.label.contains(large ? "20.6°C" : "69.0°F"))
        XCTAssertLessThanOrEqual(candidate.frame.maxX, app.frame.maxX)
        capture(large ? "Response-large-preview" : "Response-preview")
        let unsupported = app.staticTexts["No comparable warming observations. Keep the current routine."]
        reveal(unsupported, app); capture(large ? "Response-large-unsupported" : "Response-unsupported")
        reveal(preview, app); preview.tap()
        let reason = app.staticTexts["response.previewReason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 10)); reveal(reason, app)
        XCTAssertEqual(reason.label, "Fresh occupied-bed readings are unavailable.")
        XCTAssertFalse(candidate.exists)
        capture(large ? "Response-large-withdrawn" : "Response-withdrawn")
        XCTAssertFalse(app.buttons["Apply"].exists); XCTAssertFalse(app.buttons["Activate"].exists)
        app.terminate()
    }
    private func open(mode: String, large: Bool, light: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-uiRoute", "sleep", "-household.personalWorkspaceActive", "NO", "-userDefaultSide", "left",
            "-uiTargetResponseMode", mode, "-temperatureFormat", large ? "celsius" : "fahrenheit", "-appearance", large || light ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let journey = app.buttons["learning.open"]
        XCTAssertTrue(journey.waitForExistence(timeout: 30)); reveal(journey, app); journey.tap()
        XCTAssertTrue(app.navigationBars["Learning journey"].waitForExistence(timeout: 10))
        let link = app.buttons["learning.response"]; reveal(link, app); link.tap()
        XCTAssertTrue(app.navigationBars["Temperature response"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Practice · artificial response observations"].exists)
        return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let bottomInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 32 : 120
        for _ in 0..<32 {
            if element.exists {
                let frame = element.frame
                if frame.height > 0, frame.minY >= 120, frame.maxY <= app.frame.maxY - bottomInset { return }
                if frame.minY < 120 { scroll(app, upward: false); continue }
            }
            scroll(app, upward: true)
        }
        capture("Response-unreachable"); XCTFail("The response control is not reachable: \(element)")
    }
    private func scroll(_ app: XCUIApplication, upward: Bool) {
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        (upward ? lower : upper).press(forDuration: 0.05, thenDragTo: upward ? upper : lower, withVelocity: .slow, thenHoldForDuration: 0)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
