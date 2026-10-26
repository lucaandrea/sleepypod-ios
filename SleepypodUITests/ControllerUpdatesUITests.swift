import XCTest

@MainActor final class ControllerUpdatesUITests: XCTestCase {
    func testReviewedUpdateObservesChangedBuildWithoutLiveEffects() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.updates"], app)
        XCTAssertTrue(app.navigationBars["Updates"].waitForExistence(timeout: 5))
        reveal(app.buttons["updates.review"], app); capture(app, "Updates-installed")
        tap(app.buttons["updates.review"], app)
        let consent = app.switches["updates.allowInternet"]
        reveal(consent, app); capture(app, "Updates-review")
        XCTAssertFalse(app.buttons["updates.start"].isEnabled)
        consent.tap(); tap(app.buttons["updates.start"], app)
        let confirm = app.buttons["updates.confirmStart"].firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        let outcome = app.staticTexts["updates.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5)); reveal(outcome, app, up: false)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Controller reports a changed build'"), object: outcome)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 20), .completed)
        capture(app, "Updates-changed-build")
        let network = app.staticTexts["updates.network"]; reveal(network, app)
        XCTAssertEqual(network.label, "Network: local only"); capture(app, "Updates-network")
        tap(app.buttons["updates.dismiss"], app)
        let finish = app.buttons["updates.confirmDismiss"].firstMatch; XCTAssertTrue(finish.waitForExistence(timeout: 4)); finish.tap()
        XCTAssertTrue(app.buttons["updates.review"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["updates.outcome"].exists)
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
