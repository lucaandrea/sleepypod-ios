import XCTest

@MainActor final class BiometricWaveformsUITests: XCTestCase {
    func testInspectSelectReviewAndRetainSyntheticWaveformInputs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.biometricProfiles"], app); tap(app.buttons["profiles.backtests"], app)
        tap(app.buttons["backtests.createDataset"], app); tap(app.buttons["datasets.demoSleeper"], app); tap(app.buttons["datasets.sessions"], app)
        tap(app.buttons["datasets.session.100"], app); tap(app.buttons["datasets.includeSession"], app)
        app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        tap(app.buttons["datasets.review"], app); tap(app.buttons["datasets.freeze"], app); tap(app.buttons["datasets.inspectSaved"], app)
        tap(app.buttons["datasets.waveforms"], app)
        XCTAssertTrue(app.navigationBars["Retain waveforms"].waitForExistence(timeout: 5)); capture(app, "Waveforms-resources")
        tap(app.buttons["waveforms.inspectNext"], app)
        let notice = app.staticTexts["waveforms.scanNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5)); XCTAssertTrue(notice.label.contains("Archive inspected"))
        capture(app, "Waveforms-inspection-result")
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "waveforms.source.")).firstMatch
        tap(details, app); capture(app, "Waveforms-source-details")
        reveal(app.staticTexts["waveforms.inventory"], app); capture(app, "Waveforms-recorded-inventory")
        app.navigationBars.buttons.firstMatch.tap()
        let select = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "waveforms.select.")).firstMatch
        tap(select, app); XCTAssertEqual(select.label, "Remove archive")
        // Capture the settled native label, not an intermediate Include-to-Remove animation frame.
        Thread.sleep(forTimeInterval: 0.5)
        capture(app, "Waveforms-selected")
        tap(app.buttons["waveforms.review"], app); reveal(app.buttons["waveforms.retain"], app); capture(app, "Waveforms-review")
        tap(app.buttons["waveforms.retain"], app); tap(app.buttons["waveforms.inspectSaved"], app)
        XCTAssertTrue(app.navigationBars["Frozen input details"].waitForExistence(timeout: 5)); capture(app, "Waveforms-retained-metadata")
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
