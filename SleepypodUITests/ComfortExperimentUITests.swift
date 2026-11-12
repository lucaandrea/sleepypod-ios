import XCTest

@MainActor final class ComfortExperimentUITests: XCTestCase {
    private func launch(_ mode: String = "ready", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--comfort-experiments-fixture", "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO",
            "-household.personalWorkspaceActive", "NO", "-uiExperimentScenario", mode, "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.navigationBars["Comfort comparisons"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        func visible() -> Bool {
            guard element.exists else { return false }
            let frame = element.frame
            return !frame.isEmpty && frame.midY > app.frame.minY + 110 && frame.midY < app.frame.maxY - 40 && element.isHittable
        }
        for _ in 0..<30 {
            if visible() { break }
            let upward = element.exists ? element.frame.midY > app.frame.maxY - 40 : !towardTop
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func tap(_ id: String, in app: XCUIApplication) { let element = app.buttons["experiments.\(id)"]; reveal(element, in: app); element.tap() }
    private func label(_ id: String, contains value: String, in app: XCUIApplication, towardTop: Bool = true) {
        let element = app.staticTexts["experiments.\(id)"]
        reveal(element, in: app, towardTop: towardTop)
        expectation(for: NSPredicate(format: "label CONTAINS %@", value), evaluatedWith: element); waitForExpectations(timeout: 10)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "Experiment-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func select(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["experiments.library"].waitForExistence(timeout: 10))
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "experiments.saved.")).firstMatch
        reveal(button, in: app); button.tap()
        XCTAssertTrue(app.staticTexts["experiments.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["experiments.status"].isHittable, "Opening a comparison brings its summary into view")
    }
    func testSavePlanReviewControlThenStop() {
        let app = launch("empty")
        label("library", contains: "comfortable", in: app); capture("empty-light")
        tap("preview", in: app); label("review", contains: "69", in: app); capture("plan-review-light")
        tap("save", in: app); label("status", contains: "saved", in: app)
        label("controlStatus", contains: "not authorized", in: app)
        tap("reviewControl", in: app); label("controlReview", contains: "Allow", in: app); capture("control-review-light")
        tap("allow", in: app); label("status", contains: "Scheduled", in: app)
        tap("stop", in: app); label("status", contains: "ended", in: app); capture("stopped-light"); app.terminate()
    }
    func testLostAuthorizationAndPartialStopReadBeforeExplicitFinish() {
        var app = launch("lost"); select(app); tap("reviewControl", in: app); tap("allow", in: app)
        label("error", contains: "uncertain", in: app); capture("lost-reply-light")
        tap("reconcile", in: app); label("status", contains: "Scheduled", in: app); app.terminate()
        app = launch("partialStop"); select(app); tap("reviewControl", in: app); tap("allow", in: app); tap("stop", in: app)
        label("error", contains: "uncertain", in: app); tap("reconcile", in: app)
        label("status", contains: "Finish stopping", in: app); capture("partial-stop-light")
        tap("stop", in: app); label("status", contains: "ended", in: app); app.terminate()
    }
    func testUnknownCommandReadbackDoesNotBecomePhysicalProof() {
        let app = launch("unknown"); select(app)
        tap("recover.left", in: app); label("notice", contains: "No temperature command was replayed", in: app)
        label("status", contains: "Saved comparison · control ended", in: app)
        XCTAssertEqual(app.buttons["experiments.stop"].label, "Close saved comparison")
        label("controlStatus", contains: "ended", in: app)
        let receipts = app.buttons["Latest command receipts"]; reveal(receipts, in: app); receipts.tap()
        reveal(app.staticTexts["Earlier command outcome is unconfirmed."], in: app)
        capture("recovered-receipt-light"); app.terminate()
    }
    func testMorningFeedbackSavesActualRating() {
        let app = launch("feedback"); select(app)
        tap("feedbackDate", in: app); app.buttons["2026-11-13"].tap()
        reveal(app.switches["I used the bed for the full night"], in: app); app.switches["I used the bed for the full night"].tap()
        tap("feedbackSave", in: app); label("notice", contains: "Morning feedback saved", in: app)
        label("savedFeedback", contains: "comfort 5/10", in: app, towardTop: false); capture("feedback-light"); app.terminate()
    }
    func testReadinessErrorAndLoadingHaveHonestStates() {
        var app = launch("unqualified"); select(app); tap("reviewControl", in: app)
        label("error", contains: "seven matching nights", in: app)
        label("qualificationHelp", contains: "Ask your household owner", in: app, towardTop: false)
        XCTAssertTrue(app.staticTexts["experiments.qualificationHelp"].label.contains("Preview night reports"))
        capture("qualification-light")
        XCTAssertTrue(app.buttons["experiments.stop"].exists); app.terminate()
        app = launch("ownerUnqualified"); select(app); tap("reviewControl", in: app)
        label("qualificationHelp", contains: "Open Autopilot → Personal comfort", in: app, towardTop: true)
        XCTAssertFalse(app.staticTexts["experiments.qualificationHelp"].label.contains("Ask your household owner"))
        capture("qualification-owner-light"); app.terminate()
        app = launch("error"); label("error", contains: "could not be verified", in: app)
        XCTAssertTrue(app.buttons["experiments.open"].isEnabled); capture("error-light"); app.terminate()
        app = launch("loading"); XCTAssertTrue(app.staticTexts["Checking your comparison…"].waitForExistence(timeout: 5))
        capture("loading-light"); app.terminate()
    }
    func testLargestTextKeepsReviewAndStopReachable() {
        let app = launch("owner", large: true); select(app)
        reveal(app.staticTexts["experiments.status"], in: app); capture("detail-dark-largest-text")
        tap("reviewControl", in: app); reveal(app.buttons["experiments.allow"], in: app)
        XCTAssertGreaterThanOrEqual(app.buttons["experiments.allow"].frame.height, 44); capture("review-dark-largest-text")
        tap("allow", in: app); tap("stop", in: app); label("status", contains: "ended", in: app, towardTop: false)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            reveal(app.staticTexts["experiments.status"], in: app, towardTop: true); capture("tablet-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        app.terminate()
    }
}
