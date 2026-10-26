import XCTest
import UIKit

@MainActor final class SystemDashboardUITests: XCTestCase {
    func testRuntimeTonightAndThermalNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        let overview = app.buttons["system.dashboard"]
        reveal(overview, app: app); overview.tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 8))
        let performance = app.buttons["dashboard.performance"]
        reveal(performance, app: app); performance.tap()
        reveal(app.staticTexts["Array buffers"], app: app)
        capture(app, "Dashboard-runtime")
        let protection = app.buttons["dashboard.protection"]
        reveal(protection, app: app)
        XCTAssertTrue(protection.isHittable)
        capture(app, "Dashboard-maintenance")
        let water = app.buttons["dashboard.priming"]
        reveal(water, app: app); water.tap()
        XCTAssertTrue(app.navigationBars["Water & Priming"].waitForExistence(timeout: 5))
        let prime = app.buttons["Start prime"]
        XCTAssertTrue(prime.waitForExistence(timeout: 3)); prime.tap()
        let confirm = app.buttons["Start priming"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        let accepted = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Prime request accepted")).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 5))
        XCTAssertFalse(prime.isEnabled)
        capture(app, "Dashboard-water")
        app.navigationBars["Water & Priming"].buttons["Done"].tap()
        reveal(app.staticTexts["dashboard.tonightTitle"], app: app)
        capture(app, "Dashboard-tonight-curves")
        let inspect = app.sliders["dashboard.inspect"]
        reveal(inspect, app: app); inspect.adjust(toNormalizedSliderPosition: 0.55)
        XCTAssertTrue(app.staticTexts["dashboard.inspectedTime"].label.contains("Inspect"))
        capture(app, "Dashboard-tonight")
        let history = app.sliders["dashboard.history.left"]
        reveal(history, app: app); history.adjust(toNormalizedSliderPosition: 0.3)
        capture(app, "Dashboard-side-history")
        let thermal = app.buttons["dashboard.thermal.left"]
        reveal(thermal, app: app); thermal.tap()
        XCTAssertTrue(app.navigationBars["Thermal"].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<90 {
            let content = app.scrollViews["dashboard.content"]
            let surface = content.exists ? content : app
            let visible = surface.frame.intersection(app.frame).insetBy(dx: 0, dy: 60)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = element.exists && element.frame.midY < visible.minY
            if down { surface.swipeDown(velocity: .slow) } else { surface.swipeUp(velocity: .slow) }
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
