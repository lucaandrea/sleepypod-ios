import XCTest

@MainActor final class AlertInboxUITests: XCTestCase {
    func testEmptyDemoAndExplicitExampleSelectionHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["alerts.open"], app)
        XCTAssertTrue(app.navigationBars["Alerts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["alerts.empty"].waitForExistence(timeout: 5))
        capture(app, "Alerts-demo-unavailable")
        tap(app.buttons["alerts.example"], app)
        let count = app.staticTexts["alerts.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "2 unread · live inbox")
        let select = app.switches["alerts.select.3"]
        reveal(select, app); capture(app, "Alerts-example-message")
        select.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(select.value as? String, "1")
        tap(app.buttons["alerts.acknowledge"], app, up: false)
        let confirm = app.buttons["alerts.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        XCTAssertTrue(app.staticTexts["alerts.notice"].waitForExistence(timeout: 5))
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '1 unread · live inbox'"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 12), .completed)
        capture(app, "Alerts-acknowledged")
        tap(app.buttons["alerts.older"], app)
        let history = app.switches["alerts.select.1"]
        reveal(history, app); capture(app, "Alerts-expired-history")
        XCTAssertTrue(app.staticTexts["Expired · history only"].exists)
        XCTAssertFalse(app.buttons["alerts.older"].exists)
    }
    private func tap(_ element: XCUIElement, _ app: XCUIApplication, up: Bool = true) {
        reveal(element, app, up: up); XCTAssertTrue(element.isEnabled); element.tap()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, up: Bool = true) {
        for _ in 0..<80 {
            let scroll = app.scrollViews.firstMatch
            let surface = scroll.exists && scroll.isHittable ? scroll : app
            let bounds = surface.frame.intersection(app.frame), nav = app.navigationBars.firstMatch
            let top = nav.exists ? max(bounds.minY, nav.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 12))
            let frame = element.exists ? element.frame : .zero
            if element.exists, element.isHittable, visible.contains(frame) { return }
            let delta = !frame.isEmpty ? frame.midY - visible.midY : (up ? visible.height : -visible.height)
            let distance = min(0.4, max(0.08, abs(delta) / max(bounds.height, 1)))
            let direction = delta >= 0 ? 1.0 : -1.0
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
