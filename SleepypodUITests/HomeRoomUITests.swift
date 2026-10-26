import XCTest

@MainActor final class HomeRoomUITests: XCTestCase {
    private func launch(example: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings", "-uiRoomFixture", example ? "YES" : "NO"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.room"], app)
        XCTAssertTrue(app.navigationBars["Room sensors"].waitForExistence(timeout: 5)); return app
    }
    func testDemoMappingDraftCannotSaveUnverifiedInputs() {
        let app = launch(example: false)
        capture(app, "Room-demo-unavailable")
        tap(app.buttons["room.mapping"], app)
        tap(app.switches["room.map.temperature"], app)
        reveal(app.textFields["room.entity.temperature"], app); capture(app, "Room-mapping-fields")
        reveal(app.buttons["room.format.temperature"], app); capture(app, "Room-mapping-format")
        reveal(app.buttons["room.save"], app)
        XCTAssertFalse(app.buttons["room.save"].isEnabled)
        XCTAssertTrue(app.staticTexts["room.validation"].exists); capture(app, "Room-invalid-draft")
    }
    func testSyntheticReadingsPublisherHistoryAndReviewedConfiguration() {
        let app = launch(example: true)
        let value = app.scrollViews["room.screen"].staticTexts["room.value.temperature"]
        XCTAssertTrue(value.waitForExistence(timeout: 5)); XCTAssertFalse(value.label.contains("—"))
        capture(app, "Room-synthetic-readings")
        tap(app.buttons["room.publishers"], app)
        let publisher = app.buttons["Publisher 1"]
        tap(publisher, app); capture(app, "Room-publisher")
        tap(publisher, app, up: false)
        tap(app.buttons["room.history"], app)
        let export = app.buttons["room.history.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5)); reveal(export, app); capture(app, "Room-history")
        app.navigationBars["Room history"].buttons.element(boundBy: 0).tap()
        tap(app.buttons["room.mapping"], app, up: false)
        tap(app.switches["room.enabled"], app)
        tap(app.buttons["room.save"], app)
        let confirm = app.buttons["room.confirmSave"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Mapping saved.'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); capture(app, "Room-saved-mapping")
        app.navigationBars["Sensor mapping"].buttons.element(boundBy: 0).tap()
        reveal(value, app, up: false)
        let withdrawn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '—'"), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [withdrawn], timeout: 12), .completed)
        capture(app, "Room-withdrawn-reading")
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
