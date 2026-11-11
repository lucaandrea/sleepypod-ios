import XCTest
import UIKit

@MainActor final class OwnerConnectionEnrollmentUITests: XCTestCase {
    func testRejectedKeyKeepsDraftAndPreviousConnection() { verifyFailure(scenario: "authentication", large: false) }
    func testNetworkFailureAtMaximumTextSize() { verifyFailure(scenario: "network", large: true) }
    func testUnexpectedReplyHasSpecificRecovery() { verifyFailure(scenario: "invalid", large: false) }
    func testLargeTextAfterDeviceRotation() { verifyFailure(scenario: "network", large: true, landscape: true) }

    func testPendingCheckDisablesChangesUntilReadCompletes() {
        let app = launch(scenario: "pending", large: false)
        let verify = app.buttons["connection.verify"]
        reveal(verify, app); verify.tap()
        XCTAssertTrue(app.buttons["connection.example.complete"].waitForExistence(timeout: 5))
        XCTAssertFalse(verify.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "connection.address").firstMatch.isEnabled)
        capture(app, "Connection-checking")
        let reply = app.buttons["connection.example.complete"]
        reveal(reply, app); reply.tap()
        let message = app.staticTexts["connection.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5)); assertResultVisible(message, app)
        XCTAssertEqual(message.label, "Example connection verified. No saved settings changed.")
        XCTAssertTrue(verify.isEnabled)
        capture(app, "Connection-verified")
        app.terminate()
    }

    private func verifyFailure(scenario: String, large: Bool, landscape: Bool = false) {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let suffix = landscape ? "-rotated" : ""
        let app = launch(scenario: scenario, large: large)
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            // The iPhone target supports portrait only; the iPad must complete its rotation.
            if UIDevice.current.userInterfaceIdiom == .pad {
                let rotated = NSPredicate { _, _ in app.frame.width > app.frame.height }
                XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: rotated, evaluatedWith: app)], timeout: 5), .completed)
            }
        }
        capture(app, (large ? "Connection-large-form" : "Connection-form-\(scenario)") + suffix)
        let verify = app.buttons["connection.verify"]
        reveal(verify, app); verify.tap()
        let message = app.staticTexts["connection.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5)); assertResultVisible(message, app)
        XCTAssertTrue(message.label.contains("saved connection is unchanged"))
        let expected = scenario == "authentication" ? "key" : scenario == "network" ? "network route" : "usable controller status"
        XCTAssertTrue(message.label.contains(expected))
        XCTAssertTrue(verify.isEnabled)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "connection.address").firstMatch.value as? String, "https://bedroom.example.invalid")
        XCTAssertLessThanOrEqual(message.frame.maxX, app.frame.maxX)
        capture(app, "Connection-\(scenario)-recovery" + suffix)
        app.terminate()
    }

    private func launch(scenario: String, large: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-household.personalWorkspaceActive", "NO", "-podURL", "https://bedroom.example.invalid", "-podStreamURL", "",
                               "-uiConnectionExample", scenario, "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["connection.practice"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<20 {
            let viewport = scroll.frame.insetBy(dx: 0, dy: 45)
            if element.exists, element.isHittable, viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let upward = !element.exists || element.frame.midY >= viewport.minY
            let start = scroll.coordinate(withNormalizedOffset: .init(dx: 0.04, dy: upward ? 0.8 : 0.2))
            let end = scroll.coordinate(withNormalizedOffset: .init(dx: 0.04, dy: upward ? 0.2 : 0.8))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        capture(app, "Connection-unreachable"); XCTFail("Control is outside the visible connection form")
    }
    private func assertResultVisible(_ element: XCUIElement, _ app: XCUIApplication) {
        let visible = NSPredicate { _, _ in
            // iPad's bottom safe area is 20pt; don't impose the phone's larger inset.
            let bottomInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 16 : 24
            let viewport = CGRect(x: app.frame.minX, y: app.navigationBars.firstMatch.frame.maxY,
                                  width: app.frame.width, height: app.frame.maxY - bottomInset - app.navigationBars.firstMatch.frame.maxY)
            return element.exists && element.isHittable && viewport.contains(element.frame)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: visible, evaluatedWith: element)], timeout: 5), .completed,
                       "Completion must reveal its full feedback without a test-driven scroll")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
