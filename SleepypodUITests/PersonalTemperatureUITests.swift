import XCTest

@MainActor final class PersonalTemperatureUITests: XCTestCase {
    private func launch(_ mode: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--personal-temp-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    private func scroll(_ app: XCUIApplication, upward: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: upward ? 0.78 : 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: upward ? 0.3 : 0.78))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { scroll(app, upward: true) }
        if !element.isHittable { capture(app, "Unreachable-\(element.identifier)") }
        XCTAssertTrue(element.isHittable, "Could not scroll to \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testAssignedControlsDisplayChoicesReceiptAndPrivateDrafts() {
        let app = launch("assigned")
        XCTAssertTrue(app.otherElements["Target temperature"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["personal.temperature.assignment"].label, "LEFT SIDE")
        XCTAssertFalse(app.segmentedControls.buttons["Both"].exists)
        app.segmentedControls.buttons["Offset"].tap()
        app.segmentedControls.buttons["Eight Sleep"].tap()
        let plus = app.buttons["Increase temperature"]
        reveal(plus, in: app); plus.tap()
        capture(app, "Personal-assigned-temperature")
        let receipt = app.buttons["Check receipt"].firstMatch
        reveal(receipt, in: app); receipt.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Controller acknowledged")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "Personal-command-receipt")
        app.buttons["Account"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["household.draftOnly"].waitForExistence(timeout: 5))
        app.buttons["Weekly routine drafts"].tap()
        XCTAssertTrue(app.staticTexts["household.routines.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["household.routines.status"].label, "Draft only")
        app.terminate()
    }
    func testSoloMixedTargetsLargeTextAndExplicitWakeRoutingFit() {
        let app = launch("solo", large: true)
        XCTAssertTrue(app.otherElements["Target temperature"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.otherElements["Target temperature"].value as? String == "Mixed, requested")
        capture(app, "Personal-solo-large-text")
        let stop = app.buttons["Stop vibration"]
        reveal(stop, in: app)
        XCTAssertTrue(stop.isEnabled)
        XCTAssertGreaterThanOrEqual(stop.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(stop.frame.maxX, app.frame.maxX)
        capture(app, "Personal-solo-stop-controls")
        let routing = app.staticTexts["personal.temperature.wakeRouting"]
        reveal(routing, in: app)
        XCTAssertEqual(routing.label, "Scheduled vibration · Left")
        capture(app, "Personal-solo-readings-routing")
        app.terminate()
    }
    func testUnknownOutcomeBlocksAdjustmentsButLeavesStopsAndReceiptReachable() {
        let app = launch("unknown")
        XCTAssertTrue(app.otherElements["Target temperature"].waitForExistence(timeout: 20))
        let plus = app.buttons["Increase temperature"]
        reveal(plus, in: app); plus.tap()
        let stop = app.buttons["Stop vibration"]
        reveal(stop, in: app); XCTAssertTrue(stop.isEnabled)
        let receipt = app.buttons["Check receipt"].firstMatch
        reveal(receipt, in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Outcome unknown")).firstMatch.exists)
        receipt.tap()
        capture(app, "Personal-unknown-receipt")
        for _ in 0..<8 where !plus.isHittable { scroll(app, upward: false) }
        XCTAssertFalse(plus.isEnabled)
        app.terminate()
    }
    func testUnassignedAndDisabledAccountsCannotOpenTemperatureControls() {
        for mode in ["unassigned", "disabled"] {
            let app = launch(mode)
            XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.otherElements["Target temperature"].exists)
            XCTAssertFalse(app.tabBars.firstMatch.exists)
            XCTAssertTrue(app.staticTexts["household.draftOnly"].exists)
            capture(app, "Personal-\(mode)-preparation")
            app.terminate()
        }
    }
}
