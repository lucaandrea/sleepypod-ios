import XCTest
import UIKit

@MainActor final class PredictiveTargetUITests: XCTestCase {
    func testResearchComparisonAndExpiry() { verify(large: false) }
    func testAccessibleResearchComparison() { verify(large: true) }

    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-uiRoute", "sleep", "-household.personalWorkspaceActive", "NO", "-userDefaultSide", "left",
            "-uiTargetResponseMode", "ready", "-temperatureFormat", large ? "celsius" : "fahrenheit", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let journey = app.buttons["learning.open"]
        XCTAssertTrue(journey.waitForExistence(timeout: 30)); reveal(journey, app); journey.tap()
        XCTAssertTrue(app.navigationBars["Learning journey"].waitForExistence(timeout: 10))
        let response = app.buttons["learning.response"]
        XCTAssertTrue(response.waitForExistence(timeout: 10)); reveal(response, app); response.tap()
        XCTAssertTrue(app.navigationBars["Temperature response"].waitForExistence(timeout: 10))
        let refresh = app.buttons["predictive.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10)); reveal(refresh, app)
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 44); refresh.tap()
        let choice = app.staticTexts["predictive.choice"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8)); reveal(choice, app)
        XCTAssertTrue(choice.label.contains(large ? "20.6°C" : "69.0°F"))
        XCTAssertTrue(choice.label.contains("experiment candidate"))
        XCTAssertLessThanOrEqual(choice.frame.maxX, app.frame.maxX)
        capture(large ? "Predictive-large" : "Predictive-dark")
        XCTAssertFalse(app.buttons["Apply"].exists); XCTAssertFalse(app.buttons["Activate"].exists)
        XCTAssertTrue(app.staticTexts["predictive.expired"].waitForExistence(timeout: 20))
        XCTAssertFalse(choice.exists)
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let inset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 32 : 120
        for _ in 0..<40 {
            let viewport = CGRect(x: app.frame.minX, y: app.frame.minY + 110,
                                  width: app.frame.width, height: app.frame.height - 110 - inset)
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable { return }
            // SwiftUI can expose an offscreen row with a zero frame before laying it out.
            let upwards = frame.isEmpty || frame.midY >= viewport.minY
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
            (upwards ? lower : upper).press(forDuration: 0.1, thenDragTo: upwards ? upper : lower, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        capture("Predictive-unreachable")
        print(app.debugDescription)
        XCTFail("Research control is not reachable: \(element)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
