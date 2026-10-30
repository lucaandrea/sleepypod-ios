import XCTest

@MainActor final class PersonalHistoryUITests: XCTestCase {
    private func launch(_ mode: String = "ready", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--history-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20)); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 40 }
        for _ in 0..<60 {
            if visible() { break }
            let upward = !element.exists || element.frame.midY > app.frame.maxY - 40
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: upward ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    private func open(_ app: XCUIApplication) {
        let link = app.buttons["history.accountLink"]; reveal(link, in: app); link.tap()
        XCTAssertTrue(app.navigationBars["Your recordings"].waitForExistence(timeout: 10))
    }
    private func firstRecord(_ app: XCUIApplication) -> XCUIElement { app.buttons["history.record.10000000-0000-4000-8000-000000000001"] }
    func testPresenceDetailRetainsSourceAndLoadsOlderFullInterval() {
        let app = launch(); open(app)
        let first = firstRecord(app); reveal(first, in: app); XCTAssertTrue(first.label.contains("Reported in bed")); capture(app, "Personal-recordings-presence")
        first.tap(); XCTAssertTrue(app.navigationBars["Recording"].waitForExistence(timeout: 5))
        let meaning = app.staticTexts["history.detailMeaning"]; reveal(meaning, in: app); XCTAssertTrue(meaning.label.contains("not confirmed sleep"))
        capture(app, "Personal-recording-source"); app.navigationBars.buttons.element(boundBy: 0).tap()
        let more = app.buttons["history.more"]; reveal(more, in: app); more.tap()
        let older = app.buttons["history.record.10000000-0000-4000-8000-000000000099"]; reveal(older, in: app); older.tap()
        let interval = app.staticTexts["history.fullInterval"]; reveal(interval, in: app); XCTAssertTrue(interval.label.contains("full interval"))
        capture(app, "Personal-recording-overlap"); app.terminate()
    }
    func testVitalsNullAndMovementKeepTheirOwnMeanings() {
        let app = launch(); open(app)
        let vitals = app.segmentedControls.buttons["Vitals"]; reveal(vitals, in: app); vitals.tap()
        let first = firstRecord(app); reveal(first, in: app); first.tap()
        let missing = app.descendants(matching: .any).matching(identifier: "history.metric.Breathing rate").firstMatch
        reveal(missing, in: app); XCTAssertTrue(missing.label.contains("Unavailable"))
        let hrv = app.staticTexts["history.hrvMeaning"]; reveal(hrv, in: app); XCTAssertTrue(hrv.label.contains("not interchangeable")); capture(app, "Personal-recording-vitals")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let movement = app.segmentedControls.buttons["Movement"]; reveal(movement, in: app); movement.tap()
        reveal(first, in: app); XCTAssertTrue(first.label.contains("Movement total: 42")); first.tap()
        let meaning = app.staticTexts["The source reports a movement total without a unit. It does not identify sleep stages."]
        reveal(meaning, in: app); capture(app, "Personal-recording-movement"); app.terminate()
    }
    func testStaleCursorClearsAccumulatedRecordsAndRefreshStartsAgain() {
        let app = launch("stale"); open(app)
        let more = app.buttons["history.more"]; reveal(more, in: app); more.tap()
        let error = app.staticTexts["history.error"]; reveal(error, in: app); XCTAssertTrue(error.label.contains("snapshot changed"))
        XCTAssertFalse(firstRecord(app).exists); capture(app, "Personal-recordings-stale-cursor")
        app.buttons["history.refresh"].tap(); reveal(firstRecord(app), in: app); app.terminate()
    }
    func testLargeTextRecordingAndSourceLabelsFit() {
        let app = launch("ready", large: true); open(app)
        let vitals = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Vitals")).firstMatch
        reveal(vitals, in: app); vitals.tap(); capture(app, "Personal-recordings-large-text-filters")
        let first = firstRecord(app); reveal(first, in: app); first.tap()
        let hrv = app.staticTexts["history.hrvMeaning"]; reveal(hrv, in: app); XCTAssertTrue(hrv.label.contains("Apple Watch HRV"))
        capture(app, "Personal-recording-large-text-vitals")
        let meaning = app.staticTexts["history.detailMeaning"]; reveal(meaning, in: app); capture(app, "Personal-recording-large-text-attribution")
        app.terminate()
    }
    func testEmptyLargeTextAndDisabledStateFit() {
        var app = launch("empty", large: true); open(app)
        let empty = app.staticTexts["history.empty"]; reveal(empty, in: app); capture(app, "Personal-recordings-empty-large-text")
        XCTAssertFalse(app.buttons["history.more"].exists); app.terminate()
        app = launch("disabled")
        let link = app.buttons["history.accountLink"]; reveal(link, in: app); XCTAssertFalse(link.isEnabled)
        let availability = app.staticTexts["history.availability"]; reveal(availability, in: app); XCTAssertTrue(availability.label.contains("not enabled"))
        capture(app, "Personal-recordings-disabled"); app.terminate()
    }
}
