import XCTest

@MainActor final class SleepDataParityUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(_ appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "sleep"]
        app.launch()
        XCTAssertTrue(app.buttons["Sleep options"].waitForExistence(timeout: 15))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
    private func show(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<45 {
            if readyForInteraction(element, in: app) { break }
            let upward = element.frame.midY > app.frame.midY
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upward ? 0.70 : 0.35))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upward ? 0.35 : 0.70)))
        }
        XCTAssertTrue(readyForInteraction(element, in: app))
    }
    private func readyForInteraction(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        // Swift Charts exposes a non-hittable accessibility container even when its plot accepts gestures.
        guard element.identifier.hasPrefix("biometrics.chart.") else { return element.isHittable }
        let visible = app.frame.insetBy(dx: 16, dy: 130)
        let frame = element.frame
        return frame.height > 0 && visible.intersection(frame).height >= frame.height * 0.85
    }
    private func heartChart(in app: XCUIApplication) -> XCUIElement {
        let charts = app.otherElements.matching(identifier: "biometrics.chart.heartRate").allElementsBoundByIndex
        return charts.filter { $0.frame.height > 50 }.min { $0.frame.height < $1.frame.height }
            ?? app.otherElements["biometrics.chart.heartRate"]
    }
    private func openBiometrics(_ app: XCUIApplication) {
        app.buttons["Sleep options"].tap()
        let option = app.buttons["sleep.openBiometrics"]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Biometrics"].waitForExistence(timeout: 6))
    }
    func testSleepEditorSaveAndRawSensorFiles() {
        let app = launch()
        let edit = app.buttons["sleep.editTimes"]; XCTAssertTrue(edit.waitForExistence(timeout: 8)); edit.tap()
        XCTAssertTrue(app.navigationBars["Edit sleep record"].waitForExistence(timeout: 3))
        capture(app, "Sleep-edit-times")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["sleep.editTimes"].waitForExistence(timeout: 8))
        app.buttons["Sleep options"].tap(); app.buttons["sleep.openRawData"].tap()
        XCTAssertTrue(app.navigationBars["Raw data"].waitForExistence(timeout: 4))
        capture(app, "Sleep-raw-export")
        let files = app.buttons["sleep.sensorFiles"]
        XCTAssertTrue(files.waitForExistence(timeout: 4)); files.tap()
        XCTAssertTrue(app.staticTexts["00001054.RAW"].waitForExistence(timeout: 4))
        app.staticTexts["00001054.RAW"].tap()
        capture(app, "Sleep-raw-sensor-files")
        XCTAssertFalse(app.buttons["Delete 00001054.RAW"].exists)
        app.navigationBars.buttons["Done"].tap()
    }
    func testBiometricsZoomRawLogAndResponsiveLayout() {
        let app = launch("Light")
        openBiometrics(app)
        let zoom = app.buttons["Zoom in"]; XCTAssertTrue(zoom.waitForExistence(timeout: 12)); show(zoom, in: app); zoom.tap()
        XCTAssertTrue(app.staticTexts["biometrics.zoomStatus"].label.contains("2×"))
        capture(app, "Sleep-biometrics-zoom")
        app.buttons["Pan earlier"].tap()
        app.buttons["Reset"].tap()
        let movement = app.staticTexts["Position changes"]
        show(movement, in: app)
        XCTAssertTrue(movement.isHittable); movement.tap(); capture(app, "Sleep-position-changes")
        let raw = app.buttons["Raw log"]
        show(raw, in: app)
        XCTAssertTrue(raw.isHittable); capture(app, "Sleep-biometrics-sessions"); raw.tap()
        XCTAssertTrue(app.navigationBars["Raw log"].waitForExistence(timeout: 4))
        capture(app, "Sleep-raw-log")
        app.searchFields.firstMatch.tap(); app.searchFields.firstMatch.typeText("no-such-record")
        XCTAssertTrue(app.staticTexts["0 original readings"].waitForExistence(timeout: 3))
        let closeSearch = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == 'close'")).firstMatch
        if closeSearch.exists { closeSearch.tap() }
        app.navigationBars.buttons["Done"].tap()
        let presence = app.staticTexts["Live presence"]
        show(presence, in: app)
        XCTAssertTrue(presence.isHittable); presence.tap(); capture(app, "Sleep-live-presence")
    }
    func testBiometricsSessionFocusPointRangeAndPinch() {
        let app = launch()
        openBiometrics(app)
        app.segmentedControls.buttons["Week"].tap()
        let collapse = app.switches["biometrics.collapseGaps"]; show(collapse, in: app)
        if collapse.value as? String == "1" { collapse.tap() }
        capture(app, "Sleep-biometric-real-time")
        collapse.tap()
        let first = app.buttons["biometrics.session.0"]; show(first, in: app)
        capture(app, "Sleep-biometric-session-detail"); first.tap()
        XCTAssertTrue(app.buttons["Reset"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["biometrics.zoomStatus"].label.hasPrefix("1×"))
        var chart = heartChart(in: app)
        show(chart, in: app)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.staticTexts["biometrics.reading.heartRate"].waitForExistence(timeout: 3))
        capture(app, "Sleep-biometric-inspection")
        let zoomBefore = Double(app.staticTexts["biometrics.zoomStatus"].label.components(separatedBy: "×")[0]) ?? 0
        chart.pinch(withScale: 1.5, velocity: 1)
        let zoomAfter = Double(app.staticTexts["biometrics.zoomStatus"].label.components(separatedBy: "×")[0]) ?? 0
        XCTAssertGreaterThanOrEqual(zoomAfter, zoomBefore)
        let select = app.switches["Select a range"]; show(select, in: app); select.tap()
        // Range mode rebuilds the chart's accessibility subtree.
        chart = heartChart(in: app)
        show(chart, in: app)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        let focus = app.buttons["Focus selected range"]; show(focus, in: app)
        XCTAssertTrue(focus.isEnabled); focus.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: select)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 3), .completed)
        XCTAssertFalse(app.staticTexts["biometrics.reading.heartRate"].exists)
        capture(app, "Sleep-biometric-focused-range")
        app.buttons["Reset"].tap()
        XCTAssertTrue(app.staticTexts["biometrics.zoomStatus"].label.hasPrefix("1×"))
    }
    func testWatchImportReviewAndImportedComparison() {
        let app = launch()
        app.buttons["Sleep options"].tap(); app.buttons["sleep.openBiometrics"].tap()
        let upload = app.buttons["sleep.importWatch"]; XCTAssertTrue(upload.waitForExistence(timeout: 12)); upload.tap()
        XCTAssertTrue(app.navigationBars["Import Apple Watch data"].waitForExistence(timeout: 4))
        capture(app, "Sleep-watch-import")
        XCTAssertFalse(app.buttons["Choose Health export"].isEnabled)
        app.navigationBars.buttons["Done"].tap()
        app.navigationBars.buttons["Sleep"].tap()
        let imported = app.buttons["sleep.importedWatch"]
        for _ in 0..<12 { if imported.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(imported.isHittable); imported.tap()
        XCTAssertTrue(app.buttons["Imported on Pod"].waitForExistence(timeout: 5))
        capture(app, "Sleep-imported-watch-comparison")
    }
}
