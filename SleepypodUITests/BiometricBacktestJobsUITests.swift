import XCTest

@MainActor final class BiometricBacktestJobsUITests: XCTestCase {
    func testSharedCandidateQueueReviewAndCancellation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.biometricProfiles"], app)
        tap(app.buttons["profiles.library"], app); tap(app.buttons["profiles.new"], app)
        let parameter = app.textFields["candidate.number.heart_rate.trackingToleranceBpm"]
        tap(parameter, app); parameter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "18\n")
        tap(app.buttons["candidate.review"], app); tap(app.buttons["candidate.save"], app)
        XCTAssertTrue(app.staticTexts["Candidate saved"].waitForExistence(timeout: 5))
        for _ in 0..<6 {
            if app.navigationBars["Biometric calibration"].exists { break }
            app.navigationBars.buttons.firstMatch.tap()
        }
        tap(app.buttons["profiles.backtests"], app)
        tap(app.buttons["backtests.createDataset"], app); tap(app.buttons["datasets.demoSleeper"], app); tap(app.buttons["datasets.sessions"], app)
        tap(app.buttons["datasets.session.100"], app); tap(app.buttons["datasets.includeSession"], app)
        app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["datasets.review"], app); tap(app.buttons["datasets.freeze"], app); tap(app.buttons["datasets.inspectSaved"], app)
        tap(app.buttons["datasets.experiment"], app); tap(app.buttons["experiments.review"], app)
        tap(app.buttons["experiments.save"], app); tap(app.buttons["experiments.inspectSaved"], app); tap(app.buttons["experiments.prepareJob"], app)
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "jobs.candidate.")).firstMatch
        tap(candidate, app); capture(app, "Jobs-selected-candidate")
        tap(app.buttons["jobs.review"], app); capture(app, "Jobs-review")
        reveal(app.buttons["jobs.queue"], app); capture(app, "Jobs-queue-action")
        tap(app.buttons["jobs.queue"], app); tap(app.buttons["jobs.inspectSaved"], app)
        XCTAssertTrue(app.navigationBars["Evaluation job"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["jobs.state"].label, "Queued"); capture(app, "Jobs-queued")
        tap(app.buttons["jobs.inputs"], app); capture(app, "Jobs-pinned-inputs")
        tap(app.buttons["jobs.cancel"], app)
        let confirm = app.buttons["jobs.confirmCancel"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let state = app.staticTexts["jobs.state"]
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Cancelled"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        reveal(state, app); capture(app, "Jobs-cancelled")
        for _ in 0..<10 {
            if app.navigationBars["Backtests"].exists { break }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["Backtests"].exists)
        tap(app.buttons["backtests.jobs"], app)
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "jobs.inspect.")).firstMatch
        reveal(detail, app); capture(app, "Jobs-library")
        tap(detail, app); XCTAssertEqual(app.staticTexts["jobs.state"].label, "Cancelled")
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
