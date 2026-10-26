import XCTest
import UIKit

@MainActor final class TemperatureApplicationUITests: XCTestCase {
    private func launch(_ scenario: String = "normal") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-uiRoute", "temperatureApplications",
            "-uiTemperatureApplicationScenario", scenario, "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Temperature applications"].waitForExistence(timeout: 15))
        return app
    }
    func testReadOnlyOutcomesAuditAndSideSelection() {
        let app = launch()
        let target = app.staticTexts["temperatureApplications.target.2"]
        reveal(target, app); capture(app, "Applications-unknown")
        let details = app.buttons["temperatureApplications.audit.2"]
        reveal(details, app); details.tap()
        let identity = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Attempt ")).firstMatch
        reveal(identity, app); capture(app, "Applications-audit")
        let accepted = app.staticTexts["temperatureApplications.target.1"]
        reveal(accepted, app); capture(app, "Applications-accepted")
        let side = app.buttons["temperatureApplications.side"].firstMatch
        reveal(side, app, upward: true); side.tap(); app.buttons["Right side"].tap()
        let empty = app.staticTexts["No recorded applications"]
        reveal(empty, app); capture(app, "Applications-other-side")
    }
    func testUnavailableDoesNotBecomeEmpty() {
        let app = launch("unavailable"), error = app.staticTexts["temperatureApplications.error"]
        reveal(error, app); XCTAssertTrue(error.label.contains("does not offer"))
        XCTAssertFalse(app.staticTexts["No recorded applications"].exists); capture(app, "Applications-unavailable")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, upward: Bool = false) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<16 {
            if element.exists && element.isHittable && element.frame.minY > 115 && element.frame.maxY < scroll.frame.maxY - 8 { return }
            let up = element.exists ? element.frame.midY < 115 : upward
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.3 : 0.75)).press(forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.75 : 0.3)))
        }
        XCTFail("Unreachable \(element), frame \(element.frame)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
