import XCTest

@MainActor final class PersonalComfortUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "comfort", "-uiComfortExample", "YES", "-appearance", "Dark"]
        app.launch(); XCTAssertTrue(app.buttons["comfort.configure"].waitForExistence(timeout: 15)); return app
    }
    func testPreviewGuardTimingAndCheckInRemainLocalAndReachable() {
        let app = launch(); capture(app, "Comfort-overview")
        app.buttons["comfort.configure"].tap()
        let mode = app.segmentedControls["comfort.config.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.buttons["Preview"].tap()
        let follow = app.switches["comfort.followBedtime"], guardControl = app.switches["comfort.sensorGuard"]
        reveal(guardControl, app); XCTAssertFalse(follow.isEnabled); guardControl.tap()
        reveal(follow, app); XCTAssertTrue(follow.isEnabled); follow.tap(); capture(app, "Comfort-settings")
        app.buttons["comfort.config.save"].tap()
        let stop = app.buttons["comfort.stop"]; XCTAssertTrue(stop.waitForExistence(timeout: 6)); reveal(stop, app); capture(app, "Comfort-preview")
        reveal(app.staticTexts["Your Pod baseline"], app); capture(app, "Comfort-baseline")
        reveal(app.staticTexts["Bed-entry timing"], app); capture(app, "Comfort-bed-entry")
        let feedback = app.buttons["comfort.feedback.save"]; reveal(feedback, app); feedback.tap()
        let notice = app.staticTexts["comfort.notice"]
        expectation(for: NSPredicate(format: "label == 'Check-in saved.'"), evaluatedWith: notice)
        waitForExpectations(timeout: 6)
        reveal(stop, app); stop.tap()
        expectation(for: NSPredicate(format: "label == 'Personal comfort off'"), evaluatedWith: app.staticTexts["comfort.mode"])
        waitForExpectations(timeout: 6); capture(app, "Comfort-off")
    }
    func testReportPagingAndExplicitRetestReviewCannotQualifyDemo() {
        let app = launch()
        let report = app.buttons["comfort.report." + String(repeating: "a", count: 64)]
        reveal(report, app); capture(app, "Comfort-night-list"); report.tap()
        XCTAssertTrue(app.navigationBars["Preview report"].waitForExistence(timeout: 6)); capture(app, "Comfort-night-summary")
        let next = app.buttons["comfort.observations.next"]; reveal(next, app); capture(app, "Comfort-observations-first"); next.tap()
        let first = app.buttons["comfort.observations.first"]; XCTAssertTrue(first.waitForExistence(timeout: 6)); reveal(first, app)
        XCTAssertFalse(app.buttons["comfort.observations.next"].exists); capture(app, "Comfort-observations-next")
        let review = app.buttons["comfort.review.open"]; reveal(review, app); review.tap()
        let save = app.buttons["comfort.review.save"]; XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["comfort.review.actualNight"].exists); capture(app, "Comfort-review-retest")
        save.tap()
        XCTAssertTrue(app.staticTexts["comfort.review.notice"].waitForExistence(timeout: 6))
        reveal(app.staticTexts["Saved review"], app); capture(app, "Comfort-review-saved")
        XCTAssertTrue(app.staticTexts["Needs retest"].exists)
        app.navigationBars["Preview report"].buttons.firstMatch.tap()
        XCTAssertTrue(report.waitForExistence(timeout: 6)); reveal(report, app)
        XCTAssertTrue(app.staticTexts["Retest requested · 3 checks"].exists)
        XCTAssertTrue(app.staticTexts["0 / 7 minimum"].exists); capture(app, "Comfort-review-retained")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<45 {
            let scroll = app.scrollViews.firstMatch, bounds = scroll.frame.intersection(app.frame)
            let top = max(bounds.minY + 12, app.navigationBars.firstMatch.frame.maxY + 12)
            let frame = element.exists ? element.frame : .zero
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 20))
            if element.exists, element.isHittable, visible.contains(frame) { return }
            let direction = frame.isEmpty || frame.midY >= visible.midY ? 1.0 : -1.0
            let distance = min(0.4, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) { let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}
