import XCTest

@MainActor final class PersonalQuietUITests: XCTestCase {
    private func launch(_ mode: String = "ready", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--personal-quiet-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        func visible() -> Bool {
            guard element.exists else { return false }
            let frame = element.frame
            return !frame.isEmpty && frame.midY > app.frame.minY + 110 && frame.midY < app.frame.maxY - 40 && element.isHittable
        }
        for _ in 0..<40 {
            if visible() { break }
            let upward = element.exists ? element.frame.midY > app.frame.maxY - 40 : !towardTop
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func open(_ app: XCUIApplication) {
        let link = app.buttons["quiet.accountLink"]; reveal(link, in: app); link.tap()
        XCTAssertTrue(app.navigationBars["Quiet time"].waitForExistence(timeout: 10))
    }
    private func tap(_ identifier: String, in app: XCUIApplication) { let button = app.buttons[identifier]; reveal(button, in: app); button.tap() }
    private func label(_ identifier: String, contains text: String, in app: XCUIApplication) {
        let element = app.staticTexts[identifier]
        reveal(element, in: app, towardTop: true)
        let expected = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        expectation(for: expected, evaluatedWith: element); waitForExpectations(timeout: 10)
    }
    func testIdleStartUpdateAndEndUseExplicitActions() {
        let app = launch("idle"); open(app)
        label("quiet.sharedState", contains: "No quiet", in: app); capture("Quiet-idle-light")
        tap("quiet.duration", in: app); app.buttons["30 minutes"].tap()
        tap("quiet.save", in: app)
        label("quiet.notice", contains: "saved on the Pod", in: app)
        reveal(app.staticTexts["quiet.sharedState"], in: app); capture("Quiet-active-light")
        tap("quiet.duration", in: app); app.buttons["8 hours"].tap(); tap("quiet.save", in: app)
        label("quiet.notice", contains: "saved on the Pod", in: app)
        tap("quiet.end", in: app); label("quiet.sharedState", contains: "No quiet", in: app)
        label("quiet.notice", contains: "request ended", in: app); app.terminate()
    }
    func testEndingOwnRequestPreservesPartnersQuietTime() {
        let app = launch(); open(app)
        label("quiet.mine", contains: "no active", in: app)
        reveal(app.staticTexts["quiet.sharedState"], in: app); capture("Quiet-partner-light")
        tap("quiet.save", in: app); label("quiet.notice", contains: "saved on the Pod", in: app)
        tap("quiet.end", in: app)
        label("quiet.notice", contains: "request ended", in: app)
        label("quiet.sharedState", contains: "Quiet time requested", in: app)
        label("quiet.mine", contains: "no active", in: app); app.terminate()
    }
    func testUncertainSaveSurvivesBackgroundThenReadsReceipt() {
        let app = launch("uncertain"); open(app); tap("quiet.save", in: app)
        label("quiet.error", contains: "unknown", in: app)
        reveal(app.buttons["quiet.reconcile"], in: app); capture("Quiet-uncertain-light")
        reveal(app.buttons["quiet.save"], in: app)
        XCTAssertFalse(app.buttons["quiet.save"].isEnabled)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.navigationBars["Personal account"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Quiet time"].exists)
        open(app); XCTAssertTrue(app.buttons["quiet.reconcile"].waitForExistence(timeout: 10))
        tap("quiet.reconcile", in: app); label("quiet.notice", contains: "saved on the Pod", in: app)
        XCTAssertFalse(app.buttons["quiet.reconcile"].exists)
        reveal(app.staticTexts["quiet.sharedState"], in: app); capture("Quiet-recovered-light"); app.terminate()
    }
    func testUnavailableReadErrorAndLoadingRemainActionable() {
        var app = launch("disabled")
        let link = app.buttons["quiet.accountLink"]; reveal(link, in: app); XCTAssertFalse(link.isEnabled)
        capture("Quiet-unavailable-light"); app.terminate()
        app = launch("error"); open(app); label("quiet.error", contains: "could not be verified", in: app)
        reveal(app.buttons["quiet.save"], in: app)
        XCTAssertFalse(app.buttons["quiet.save"].isEnabled)
        tap("quiet.refresh", in: app); label("quiet.error", contains: "could not be verified", in: app)
        reveal(app.staticTexts["quiet.error"], in: app); capture("Quiet-read-error-light"); app.terminate()
        app = launch("loading"); open(app)
        XCTAssertTrue(app.staticTexts["Checking quiet status…"].waitForExistence(timeout: 4))
        capture("Quiet-loading-light"); app.terminate()
    }
    func testLargestTextExplainsLimitsAndKeepsAllActionsReachable() {
        let app = launch(large: true); open(app)
        reveal(app.staticTexts["quiet.sharedState"], in: app)
        label("quiet.sharedState", contains: "Quiet time requested", in: app)
        reveal(app.staticTexts["quiet.sharedState"], in: app); capture("Quiet-dark-largest-text")
        let save = app.buttons["quiet.save"]; reveal(save, in: app)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        capture("Quiet-controls-dark-largest-text")
        tap("quiet.explanation", in: app)
        let caveat = app.staticTexts["Movement already underway does not stop automatically. Use the base’s Stop control if needed."]
        reveal(caveat, in: app); capture("Quiet-limits-dark-largest-text")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            reveal(save, in: app, towardTop: true); capture("Quiet-tablet-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        app.terminate()
    }
}
