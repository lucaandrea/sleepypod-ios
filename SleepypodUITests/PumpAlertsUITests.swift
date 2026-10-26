import XCTest
import UIKit

@MainActor final class PumpAlertsUITests: XCTestCase {
    func testIncidentReviewDismissalAndAcknowledgedFilter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        reveal(app.buttons["system.dashboard"], app: app); app.buttons["system.dashboard"].tap()
        let alerts = app.buttons["dashboard.pumpAlerts"]
        reveal(alerts, app: app); alerts.tap()
        XCTAssertTrue(app.navigationBars["Pump alerts"].waitForExistence(timeout: 5))
        capture(app, "PumpAlerts-active")
        let first = app.buttons["pumpAlerts.dismiss.101"]
        reveal(first, app: app); first.tap()
        let confirm = app.alerts.buttons["Dismiss"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let explanation = app.alerts.staticTexts["Clears matching blocks. Power is unchanged."]
        XCTAssertTrue(explanation.exists)
        XCTAssertLessThanOrEqual(explanation.frame.maxY, confirm.frame.minY, "Confirmation text must fit above its actions")
        XCTAssertTrue(app.alerts.buttons["Cancel"].isHittable)
        capture(app, "PumpAlerts-review")
        confirm.tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        let filter = app.switches["pumpAlerts.acknowledged"]
        reveal(filter, app: app); filter.tap()
        XCTAssertEqual(filter.value as? String, "1")
        let acknowledged = app.buttons["pumpAlerts.dismiss.100"]
        reveal(acknowledged, app: app)
        XCTAssertTrue(acknowledged.exists)
        capture(app, "PumpAlerts-acknowledged")
        let all = app.buttons["pumpAlerts.dismissAll"]
        reveal(all, app: app); all.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        let empty = app.staticTexts["No matching pump alerts"]
        reveal(empty, app: app)
        XCTAssertTrue(empty.exists)
        let result = app.staticTexts["pumpAlerts.result"]
        XCTAssertTrue(result.label.contains("2 dismissals confirmed"))
        capture(app, "PumpAlerts-empty")
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<60 {
            let alerts = app.scrollViews["pumpAlerts.content"], dashboard = app.scrollViews["dashboard.content"]
            let surface = alerts.exists ? alerts : dashboard.exists ? dashboard : app
            let visible = surface.frame.intersection(app.frame).insetBy(dx: 0, dy: 50)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = element.exists && element.frame.midY < visible.minY
            if UIDevice.current.userInterfaceIdiom == .pad {
                if down { surface.swipeDown(velocity: .slow) } else { surface.swipeUp(velocity: .slow) }
            } else {
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
                let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY + (down ? 230 : -230)))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
