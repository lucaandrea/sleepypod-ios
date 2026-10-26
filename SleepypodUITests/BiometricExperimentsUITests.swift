import XCTest

@MainActor final class BiometricExperimentsUITests: XCTestCase {
    func testFreezeExplicitProtocolAndInspectSharedLibrary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.biometricProfiles"], app); tap(app.buttons["profiles.backtests"], app)
        tap(app.buttons["backtests.createDataset"], app); tap(app.buttons["datasets.demoSleeper"], app); tap(app.buttons["datasets.sessions"], app)
        tap(app.buttons["datasets.session.100"], app); tap(app.buttons["datasets.includeSession"], app)
        app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["datasets.review"], app); tap(app.buttons["datasets.freeze"], app); tap(app.buttons["datasets.inspectSaved"], app)
        tap(app.buttons["datasets.experiment"], app)
        XCTAssertTrue(app.navigationBars["Evaluation protocol"].waitForExistence(timeout: 5)); capture(app, "Experiments-editor")
        tap(app.buttons["experiments.mode.stage_replay"], app)
        XCTAssertTrue(app.staticTexts["experiments.incomplete"].exists)
        enter("0.6", field: "quality", app: app); reveal(app.textFields["experiments.quality"], app); capture(app, "Experiments-stage-assumption")
        tap(app.switches["experiments.uncertainty"], app)
        enter("synthetic-night-seed", field: "seed", app: app)
        reveal(app.textFields["experiments.minimumNights"], app); capture(app, "Experiments-uncertainty")
        tap(app.buttons["experiments.review"], app)
        XCTAssertTrue(app.navigationBars["Review protocol"].waitForExistence(timeout: 5)); capture(app, "Experiments-review")
        reveal(app.buttons["experiments.save"], app); capture(app, "Experiments-save")
        tap(app.buttons["experiments.save"], app); tap(app.buttons["experiments.inspectSaved"], app)
        XCTAssertTrue(app.navigationBars["Experiment details"].waitForExistence(timeout: 5)); capture(app, "Experiments-saved")
        reveal(app.staticTexts["experiments.holdoutAccesses"], app)
        XCTAssertEqual(app.staticTexts["experiments.holdoutAccesses"].label, "Holdout accesses: 0")
        for _ in 0..<8 {
            if app.navigationBars["Backtests"].exists { break }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["Backtests"].exists)
        tap(app.buttons["backtests.experiments"], app)
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "experiments.inspect.")).firstMatch
        reveal(detail, app); capture(app, "Experiments-library")
        tap(detail, app); XCTAssertTrue(app.navigationBars["Experiment details"].exists)
    }
    private func enter(_ value: String, field: String, app: XCUIApplication) {
        let input = app.textFields["experiments." + field]
        tap(input, app); input.typeText(value)
        let done = app.buttons["experiments.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
    }
    private func tap(_ element: XCUIElement, _ app: XCUIApplication) {
        reveal(element, app); XCTAssertTrue(element.isEnabled); element.tap()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<90 {
            let scroll = app.scrollViews.firstMatch
            let surface = scroll.exists && scroll.isHittable ? scroll : app
            let bounds = surface.frame.intersection(app.frame), nav = app.navigationBars.firstMatch
            let top = nav.exists ? max(bounds.minY, nav.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 12))
            if element.exists, element.isHittable {
                let frame = element.frame
                if frame.height <= visible.height ? visible.contains(frame) : visible.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            }
            let down = !(element.exists && element.frame.minY < visible.minY)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.75 : 0.35)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.35 : 0.75)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
