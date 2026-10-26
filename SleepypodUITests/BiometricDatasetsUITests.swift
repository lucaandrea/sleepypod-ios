import XCTest

@MainActor final class BiometricDatasetsUITests: XCTestCase {
    func testInspectFreezeCoverageAndRelease() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap("settings.biometricProfiles", app); tap("profiles.backtests", app)
        XCTAssertTrue(app.navigationBars["Backtests"].waitForExistence(timeout: 5)); capture(app, "Datasets-workspace")
        tap("backtests.createDataset", app); tap("datasets.demoSleeper", app); tap("datasets.sessions", app)
        tap("datasets.session.102", app)
        reveal(app.buttons["datasets.includeSession"], app); XCTAssertFalse(app.buttons["datasets.includeSession"].isEnabled)
        capture(app, "Datasets-missing-readings"); app.navigationBars.buttons.firstMatch.tap()
        tap("datasets.session.100", app); capture(app, "Datasets-session-inspection")
        tap("datasets.includeSession", app); XCTAssertTrue(app.buttons["datasets.removeSession"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        tap("datasets.references", app); tap("datasets.includeReference", app); capture(app, "Datasets-reference-selection")
        app.navigationBars.buttons.firstMatch.tap(); tap("datasets.review", app)
        reveal(app.buttons["datasets.freeze"], app); capture(app, "Datasets-review")
        tap("datasets.freeze", app); tap("datasets.inspectSaved", app)
        XCTAssertTrue(app.navigationBars["Frozen input details"].waitForExistence(timeout: 5)); capture(app, "Datasets-frozen")
        tap("datasets.coverage.100", app); capture(app, "Datasets-coverage")
        app.navigationBars.buttons.firstMatch.tap(); tap("datasets.release", app)
        let confirm = app.buttons.matching(identifier: "datasets.confirmRelease").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let availability = app.staticTexts["datasets.availability"]
        expectation(for: NSPredicate(format: "label == %@", "Inputs released; metadata retained"), evaluatedWith: availability)
        waitForExpectations(timeout: 8); reveal(availability, app); capture(app, "Datasets-released")
    }
    private func tap(_ identifier: String, _ app: XCUIApplication) {
        let button = app.buttons[identifier]; reveal(button, app); XCTAssertTrue(button.isEnabled); button.tap()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<90 {
            let names = ["datasets.builderContent", "datasets.sessionsContent", "datasets.sessionContent", "datasets.referencesContent", "datasets.reviewContent", "datasets.detailContent", "datasets.coverageContent", "datasets.libraryContent", "backtests.content", "profiles.content"]
            let surface = names.map { app.scrollViews[$0] }.first { $0.exists && $0.isHittable } ?? app
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
