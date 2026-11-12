import XCTest

@MainActor final class PersonalOfflineLibraryUITests: XCTestCase {
    private func launch(_ mode: String = "saved", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--personal-offline-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Personal account"].waitForExistence(timeout: 15))
        reveal(app.buttons["personalOffline.accountLink"], in: app); app.buttons["personalOffline.accountLink"].tap()
        XCTAssertTrue(app.navigationBars["Saved readings"].waitForExistence(timeout: 5))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 50 }
        for _ in 0..<35 {
            if visible() { break }
            let upward = !element.exists || element.frame.midY > app.frame.maxY - 50
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: upward ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // Screen capture avoids XCTest's stale application crop after iPad rotation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }

    func testOfflineRecordDetailsAndOperatingWeekHaveNoActuatorControls() {
        let app = launch(); capture(app, "Personal-offline-overview-light")
        let presence = app.buttons["personalOffline.kind.presence"]; reveal(presence, in: app)
        XCTAssertTrue(presence.label.contains("Last synced")); presence.tap()
        let recording = app.buttons["personalOffline.record.10000000-0000-4000-8000-000000000001"]
        reveal(recording, in: app); capture(app, "Personal-offline-record-list"); recording.tap()
        XCTAssertTrue(app.navigationBars["Saved recording"].waitForExistence(timeout: 5))
        let metric = app.descendants(matching: .any).matching(identifier: "history.metric.Reported in bed").firstMatch
        reveal(metric, in: app); capture(app, "Personal-offline-record-detail")
        back(app); back(app)
        let week = app.buttons["personalOffline.week"]; reveal(week, in: app); capture(app, "Personal-offline-week-entry"); week.tap()
        XCTAssertTrue(app.navigationBars["Saved operating week"].waitForExistence(timeout: 5))
        capture(app, "Personal-offline-week-read-only")
        XCTAssertFalse(app.buttons["Publish"].exists); XCTAssertFalse(app.buttons["Apply my target"].exists)
        XCTAssertFalse(app.buttons["Save routine"].exists); app.terminate()
    }
    func testSavedCopySurvivesRelaunchAndRemovalDoesNotRecreateIt() {
        var app = launch(); app.terminate()
        app = launch("reopen")
        let presence = app.buttons["personalOffline.kind.presence"]; reveal(presence, in: app); XCTAssertTrue(presence.exists)
        let remove = app.buttons["personalOffline.remove"]; reveal(remove, in: app); remove.tap()
        XCTAssertTrue(app.alerts["Remove this saved copy?"].waitForExistence(timeout: 5)); capture(app, "Personal-offline-remove-confirmation")
        app.alerts.buttons["Cancel"].tap(); XCTAssertTrue(remove.exists); remove.tap()
        app.alerts.buttons["Remove saved copy"].tap()
        XCTAssertTrue(app.staticTexts["personalOffline.empty"].waitForExistence(timeout: 5)); capture(app, "Personal-offline-removed")
        app.terminate(); app = launch("reopen"); XCTAssertTrue(app.staticTexts["personalOffline.empty"].exists); app.terminate()
    }
    func testLockedStorageAndEmptyCopiesExplainRecovery() {
        var app = launch("locked")
        let error = app.staticTexts["personalOffline.error"]; reveal(error, in: app)
        XCTAssertTrue(error.label.contains("Unlock")); capture(app, "Personal-offline-storage-unavailable")
        XCTAssertFalse(app.buttons["personalOffline.kind.presence"].exists); app.terminate()
        app = launch("empty"); let empty = app.staticTexts["personalOffline.empty"]; reveal(empty, in: app)
        capture(app, "Personal-offline-empty"); app.terminate()
    }
    func testLargestTextAndDarkAppearanceKeepMeaningAndVitalDetailsReadable() {
        let app = launch(large: true)
        let meaning = app.staticTexts["personalOffline.meaning"]; reveal(meaning, in: app); capture(app, "Personal-offline-largest-text-dark")
        let vitals = app.buttons["personalOffline.kind.vitals"]; reveal(vitals, in: app); vitals.tap()
        let recording = app.buttons["personalOffline.record.10000000-0000-4000-8000-000000000002"]; reveal(recording, in: app); recording.tap()
        let missing = app.descendants(matching: .any).matching(identifier: "history.metric.Breathing rate").firstMatch
        reveal(missing, in: app); XCTAssertTrue(missing.label.contains("Unavailable")); capture(app, "Personal-offline-vitals-largest-text")
        let hrv = app.staticTexts["history.hrvMeaning"]; reveal(hrv, in: app)
        XCTAssertTrue(hrv.label.contains("not interchangeable")); capture(app, "Personal-offline-source-largest-text"); app.terminate()
    }
    func testDeviceRotationPreservesReadableNavigation() {
        let app = launch()
        let tablet = app.frame.width > 600
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        // iPhone retains its declared portrait layout; iPad supports landscape.
        let orientation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tablet ? app.frame.width > app.frame.height : app.frame.width < app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [orientation], timeout: 5), .completed)
        let presence = app.buttons["personalOffline.kind.presence"]; reveal(presence, in: app)
        presence.tap()
        let record = app.buttons["personalOffline.record.10000000-0000-4000-8000-000000000001"]; reveal(record, in: app)
        let layout = tablet ? "landscape" : "portrait-after-rotation"
        capture(app, "Personal-offline-\(layout)-recordings")
        back(app); reveal(presence, in: app); capture(app, "Personal-offline-\(layout)")
    }
}
