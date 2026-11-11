import XCTest
import UIKit

@MainActor final class OwnerRouteSettingsUITests: XCTestCase {
    func testVerifiedConnectionsCanBeEnabledAndPaused() {
        let app = launch(scenario: "success", large: false)
        capture("Routes-saved-off")
        let verify = app.buttons["routes.verify"]
        reveal(verify, app); XCTAssertTrue(verify.isEnabled); verify.tap()
        let result = app.staticTexts["routes.message"]
        expectMessage(result, containing: "Home and away connections verified", app: app)
        XCTAssertTrue(verify.isEnabled)
        capture("Routes-verified")
        let toggle = app.buttons["routes.toggle"]
        reveal(toggle, app)
        XCTAssertEqual(toggle.label, "Turn off automatic connection")
        toggle.tap()
        expectMessage(result, containing: "Automatic connection is off", app: app)
        capture("Routes-paused")
        app.terminate()
    }

    func testWrongControllerAtMaximumTextSizePreservesSavedSetup() { verifyFailure(scenario: "different", large: true) }
    func testRejectedKeyHasSpecificRecovery() { verifyFailure(scenario: "authentication", large: false) }
    func testNetworkFailureAfterRotation() { verifyFailure(scenario: "network", large: true, rotate: true) }

    private func verifyFailure(scenario: String, large: Bool, rotate: Bool = false) {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(scenario: scenario, large: large)
        if rotate {
            XCUIDevice.shared.orientation = .landscapeLeft
            if UIDevice.current.userInterfaceIdiom == .pad {
                let rotated = NSPredicate { _, _ in app.frame.width > app.frame.height }
                XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: rotated, evaluatedWith: app)], timeout: 5), .completed)
            }
        }
        capture("Routes-\(scenario)-form")
        let verify = app.buttons["routes.verify"]
        reveal(verify, app); XCTAssertTrue(verify.isEnabled); verify.tap()
        let result = app.staticTexts["routes.message"]
        let fragment = scenario == "different" ? "different controller" : "Away connection"
        expectMessage(result, containing: fragment, app: app)
        XCTAssertTrue(result.label.contains("saved setup is unchanged"))
        if scenario == "authentication" { XCTAssertTrue(result.label.contains("key")) }
        if scenario == "network" { XCTAssertTrue(result.label.contains("gateway is online")) }
        XCTAssertTrue(verify.isEnabled)
        capture("Routes-\(scenario)-recovery")
        let toggle = app.buttons["routes.toggle"]
        reveal(toggle, app)
        XCTAssertEqual(toggle.label, "Turn on automatic connection")
        let address = app.descendants(matching: .any).matching(identifier: "routes.away.address").firstMatch
        XCTAssertEqual(address.value as? String, "https://bedroom.example.invalid")
        app.terminate()
    }

    private func launch(scenario: String, large: Bool) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-household.personalWorkspaceActive", "NO", "-uiConnectionExample", "", "-uiRouteExample", scenario,
            "-appearance", large ? "Light" : "Dark", "-UIPreferredContentSizeCategoryName",
            large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["routes.practice"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["routes.toggle"].waitForExistence(timeout: 5), "The saved example profile must load")
        return app
    }

    private func expectMessage(_ message: XCUIElement, containing fragment: String, app: XCUIApplication) {
        let ready = NSPredicate { _, _ in message.exists && message.label.contains(fragment) }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: ready, evaluatedWith: message)], timeout: 10), .completed)
        let visible = NSPredicate { _, _ in
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 16 : 24
            let viewport = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: app.frame.maxY - bottom - top)
            return message.isHittable && viewport.contains(message.frame)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: visible, evaluatedWith: message)], timeout: 5), .completed,
                       "The form must reveal its complete result without a test-driven scroll")
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
        capture("Routes-unreachable"); XCTFail("Connection control is outside the visible form")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
