import XCTest
import UIKit

@MainActor final class SystemHealthThermalUITests: XCTestCase {
    func testHealthRecoveryNodeInspectionAndHistory() {
        let app = launch("system.health", title: "Health")
        let restart = app.buttons["health.restart"]
        reveal(restart, app: app); restart.tap()
        let confirmation = app.alerts.buttons["Run recovery"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3)); confirmation.tap()
        let verdict = app.staticTexts["health.verdict"]
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Simulated data is flowing"), object: verdict)
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 8), .completed)
        capture(app, "Health-recovery")
        let processor = app.buttons["health.node.piezo-processor"]
        reveal(processor, app: app); processor.tap()
        XCTAssertTrue(app.navigationBars["Piezo processor"].waitForExistence(timeout: 3))
        capture(app, "Health-stage-connections")
        app.buttons["Done"].tap()
        let live = app.buttons["health.node.out-live"]
        reveal(live, app: app); live.tap()
        XCTAssertTrue(app.navigationBars["Live stream"].waitForExistence(timeout: 3))
        reveal(app.staticTexts["Presence"], app: app)
        capture(app, "Health-live-stream")
        app.buttons["Done"].tap()
        let inspect = app.sliders["Inspect health history"]
        reveal(inspect, app: app); inspect.adjust(toNormalizedSliderPosition: 0.5)
        capture(app, "Health-history")
        let all = app.buttons["health.history.all"]
        reveal(all, app: app); all.tap()
        XCTAssertEqual(all.label, "Show fewer checks")
        capture(app, "Health-all-checks")
    }
    func testThermalRangeInspectionAndProtectionSave() {
        let app = launch("system.thermal", title: "Thermal")
        let range = app.buttons["thermal.range"]
        reveal(range, app: app); range.tap()
        let week = app.buttons["7 days"]
        XCTAssertTrue(week.waitForExistence(timeout: 3)); week.tap()
        let inspect = app.sliders["Inspect thermal history"]
        reveal(inspect, app: app); inspect.adjust(toNormalizedSliderPosition: 0.8)
        reveal(app.staticTexts["Bed and target"], app: app)
        capture(app, "Thermal-history")
        reveal(app.staticTexts["Pump rpm"], app: app)
        capture(app, "Thermal-pump-chart")
        let protection = app.buttons["thermal.protection"]
        reveal(protection, app: app); protection.tap()
        XCTAssertTrue(app.navigationBars["Pump protection"].waitForExistence(timeout: 3))
        let threshold = app.steppers["pump.threshold"]
        reveal(threshold, app: app)
        threshold.buttons["pump.threshold-Increment"].tap()
        capture(app, "Thermal-protection-draft")
        let save = app.buttons["Save protection settings"]
        reveal(save, app: app); XCTAssertTrue(save.isEnabled); save.tap()
        let notice = app.staticTexts["pump.notice"]
        reveal(notice, app: app)
        XCTAssertTrue(notice.label == "Saved to the controller.")
        capture(app, "Thermal-protection-saved")
    }
    private func launch(_ route: String, title: String) -> XCUIApplication {
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        reveal(app.buttons[route], app: app); app.buttons[route].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<100 {
            let surfaces = ["pump.content", "thermal.content", "health.content"].map { app.scrollViews[$0] }
            let surface = surfaces.first { $0.exists && $0.isHittable } ?? app
            let visible = surface.frame.intersection(app.frame).insetBy(dx: 0, dy: 50)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = element.exists && element.frame.midY < visible.minY
            let distance = min(250, visible.height * 0.4)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY + (down ? distance : -distance)))
            if UIDevice.current.userInterfaceIdiom == .pad {
                if down { surface.swipeDown(velocity: .slow) } else { surface.swipeUp(velocity: .slow) }
            } else { start.press(forDuration: 0.05, thenDragTo: end) }
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
