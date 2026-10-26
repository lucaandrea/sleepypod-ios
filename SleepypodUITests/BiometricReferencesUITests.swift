import XCTest

@MainActor final class BiometricReferencesUITests: XCTestCase {
    func testReferencePreviewCorrectionMeasurementsAndDeletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap("settings.biometricProfiles", app); tap("profiles.references", app)
        XCTAssertTrue(app.navigationBars["References"].waitForExistence(timeout: 5)); capture(app, "References-library-empty")
        tap("references.new", app); tap("references.sample", app); capture(app, "References-import")
        tap("references.preview", app)
        XCTAssertTrue(app.staticTexts["references.counts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["references.counts"].label, "6 received · 4 accepted · 1 rejected")
        reveal(app.buttons["references.save"], app); XCTAssertFalse(app.buttons["references.save"].isEnabled)
        let accept = app.switches["references.acceptRejected"]; reveal(accept, app); accept.tap()
        capture(app, "References-reviewed-partial")
        tap("references.save", app); tap("references.inspectSaved", app)
        XCTAssertTrue(app.navigationBars["Reference revision"].waitForExistence(timeout: 5)); capture(app, "References-saved")
        tap("references.measurements", app)
        XCTAssertTrue(app.navigationBars["Measurements"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Heart rate"].waitForExistence(timeout: 5)); capture(app, "References-measurements")
        let excluded = app.staticTexts["Excluded from scoring"]; reveal(excluded, app); capture(app, "References-excluded-hrv")
        app.navigationBars.buttons.firstMatch.tap()
        tap("references.correct", app); tap("references.sample", app); tap("references.preview", app)
        XCTAssertTrue(app.staticTexts["references.counts"].waitForExistence(timeout: 5))
        reveal(accept, app); accept.tap(); tap("references.save", app); tap("references.inspectSaved", app)
        XCTAssertTrue(app.staticTexts["Example watch · revision 2"].waitForExistence(timeout: 5)); capture(app, "References-correction")
        tap("references.delete", app)
        let confirm = app.buttons.matching(identifier: "references.confirmDelete").firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let available = app.staticTexts["references.availability"]
        let deleted = NSPredicate(format: "label == %@", "Source measurements deleted")
        expectation(for: deleted, evaluatedWith: available); waitForExpectations(timeout: 8)
        reveal(available, app); capture(app, "References-deleted")
    }
    private func tap(_ identifier: String, _ app: XCUIApplication) {
        let button = app.buttons[identifier]; reveal(button, app); XCTAssertTrue(button.isEnabled); button.tap()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<85 {
            let names = ["references.content", "references.importContent", "references.detailContent", "references.measurementsContent", "profiles.content"]
            let surface = names.map { app.scrollViews[$0] }.first { $0.exists && $0.isHittable } ?? app
            let bounds = surface.frame.intersection(app.frame), nav = app.navigationBars.firstMatch
            let top = nav.exists ? max(bounds.minY, nav.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 12))
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = !(element.exists && element.frame.midY < visible.minY)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.75 : 0.35)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.35 : 0.75)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
