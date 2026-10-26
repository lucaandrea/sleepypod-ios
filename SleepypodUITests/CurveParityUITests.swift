import XCTest

@MainActor
final class CurveParityUITests: XCTestCase {
    private func launch(_ appearance: String = "Dark", scenario: String = "normal") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "schedule", "-uiCurveScenario", scenario]
        app.launch()
        XCTAssertTrue(app.buttons["Schedule options"].waitForExistence(timeout: 15))
        app.buttons["Schedule options"].tap(); app.buttons["Curves"].tap()
        XCTAssertTrue(app.navigationBars["Curves"].waitForExistence(timeout: 5))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        let scroll: XCUIElement
        if app.navigationBars["Run once"].exists { scroll = app.scrollViews["curve.run.scroll"] }
        else if app.scrollViews["curve.editor.scroll"].exists { scroll = app.scrollViews["curve.editor.scroll"] }
        else { scroll = app.scrollViews["curve.library.scroll"] }
        for _ in 0..<25 {
            let viewport = scroll.frame.insetBy(dx: 0, dy: 50)
            if element.exists, element.isHittable, viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let upward = !element.exists || element.frame.midY > viewport.midY
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: upward ? 0.78 : 0.30)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: upward ? 0.30 : 0.78)))
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCreateClaimDaysEditPointRunOnceAndCancel() {
        let app = launch()
        XCTAssertTrue(app.buttons["curve.edit.1"].waitForExistence(timeout: 4))
        capture(app, "Curves-library-dark")
        let new = app.buttons["curve.new"]; reveal(new, app: app); new.tap()
        XCTAssertTrue(app.navigationBars["New curve"].waitForExistence(timeout: 3))
        app.textFields["Curve name"].tap(); app.textFields["Curve name"].typeText("Calm nights")
        let left = app.buttons["Choose days for Left"]; reveal(left, app: app); left.tap(); app.buttons["Every day"].tap()
        let preset = app.buttons["curve.preset"]; reveal(preset, app: app); preset.tap(); app.buttons["Balanced"].tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Move days and save"].waitForExistence(timeout: 3))
        capture(app, "Curves-day-move-review")
        app.buttons["Move days and save"].tap()
        let created = app.buttons["curve.edit.100"]; XCTAssertTrue(created.waitForExistence(timeout: 4)); reveal(created, app: app); created.tap()
        let point = app.buttons["Edit set point at 21:15"]; reveal(point, app: app); point.tap()
        XCTAssertTrue(app.navigationBars["Set point"].waitForExistence(timeout: 3))
        capture(app, "Curves-point-editor")
        app.navigationBars.buttons["Done"].tap()
        app.navigationBars.buttons["Save"].tap()
        let run = app.buttons["curve.run.100"]; reveal(run, app: app); run.tap()
        XCTAssertTrue(app.navigationBars["Run once"].waitForExistence(timeout: 3))
        capture(app, "Curves-run-once-review")
        let start = app.buttons["Start run once"]; reveal(start, app: app); start.tap()
        let stop = app.buttons["Stop run-once curve"]; XCTAssertTrue(stop.waitForExistence(timeout: 4))
        app.swipeDown(); app.swipeDown(); reveal(stop, app: app); stop.tap()
        XCTAssertTrue(app.staticTexts["Run once cancelled. The recurring schedule resumes."].waitForExistence(timeout: 4))
    }
    func testCurveEditorAtCurrentDeviceTextSize() {
        let app = launch("Light")
        app.buttons["curve.edit.1"].tap()
        XCTAssertTrue(app.navigationBars["Edit curve"].waitForExistence(timeout: 3))
        capture(app, "Curves-responsive-top")
        reveal(app.buttons["curve.endAction"], app: app)
        capture(app, "Curves-responsive-times")
        reveal(app.buttons["curve.preset"], app: app)
        capture(app, "Curves-responsive-preset")
        reveal(app.buttons["Edit set point at 22:00"], app: app)
        capture(app, "Curves-responsive-points")
        app.navigationBars.buttons["Cancel"].tap()
    }
    private func revealGraphPoint(_ point: XCUIElement, app: XCUIApplication) {
        let scroll = app.scrollViews["curve.editor.scroll"]
        for _ in 0..<25 {
            let bounds = scroll.frame.insetBy(dx: 8, dy: 64)
            if point.exists, point.isHittable, bounds.contains(point.frame) { return }
            let direction = !point.exists || point.frame.midY > bounds.midY ? 1.0 : -1.0
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * 0.18)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * 0.18)))
        }
        XCTFail("The graph point is not fully visible")
    }
    func testGraphPointDragRemainsADraftUntilSaved() {
        let app = launch("Light")
        app.buttons["curve.edit.1"].tap()
        let point = app.buttons["curve.handle.1"]
        revealGraphPoint(point, app: app)
        let original = point.value as? String; XCTAssertNotNil(original)
        capture(app, "Curves-drag-before")
        point.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: point.coordinate(withNormalizedOffset: .init(dx: 2, dy: -0.5)))
        XCTAssertNotEqual(point.value as? String, original)
        XCTAssertTrue(app.staticTexts["curve.dragValue"].exists)
        capture(app, "Curves-drag-draft")
        app.navigationBars.buttons["Cancel"].tap()
        let edit = app.buttons["curve.edit.1"]; reveal(edit, app: app); edit.tap()
        revealGraphPoint(app.buttons["curve.handle.1"], app: app)
        XCTAssertEqual(app.buttons["curve.handle.1"].value as? String, original, "Cancelling must not save the dragged point")
        app.navigationBars.buttons["Cancel"].tap()
    }
    func testUncertainRunOnceRequiresReloadBeforeRetry() {
        let app = launch(scenario: "uncertain-start")
        let run = app.buttons["curve.run.1"]; reveal(run, app: app); run.tap()
        let start = app.buttons["Start run once"]; reveal(start, app: app); start.tap()
        let reload = app.scrollViews["curve.run.scroll"].buttons["Reload curves"]
        XCTAssertTrue(reload.waitForExistence(timeout: 3))
        XCTAssertFalse(start.isEnabled)
        capture(app, "Curves-uncertain-start")
        reveal(reload, app: app); reload.tap()
        XCTAssertTrue(start.isEnabled)
        app.navigationBars.buttons["Cancel"].tap()
        let stop = app.buttons["Stop run-once curve"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        capture(app, "Curves-start-reconciled")
        reveal(stop, app: app); stop.tap()
        XCTAssertTrue(app.staticTexts["Run once cancelled. The recurring schedule resumes."].waitForExistence(timeout: 3))
    }
    func testLegacyApplyIsReviewedAndOfflineLibraryHasNoEditableRows() {
        let app = launch(scenario: "legacy")
        XCTAssertTrue(app.buttons["curve.edit.1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.switches["Run Weeknight"].exists)
        let more = app.buttons["More for Weeknight"]; reveal(more, app: app); more.tap()
        app.buttons["Apply to selected days"].tap()
        XCTAssertTrue(app.buttons["Apply curve"].waitForExistence(timeout: 3))
        capture(app, "Curves-legacy-apply-review")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Apply curve"].exists)
        XCTAssertFalse(app.staticTexts["Curve applied."].exists)
        more.tap(); app.buttons["Apply to selected days"].tap(); app.buttons["Apply curve"].tap()
        XCTAssertTrue(app.staticTexts["Curve applied."].waitForExistence(timeout: 4))
        app.terminate()
        let offline = launch(scenario: "offline")
        XCTAssertTrue(offline.buttons["Reload curves"].waitForExistence(timeout: 3))
        XCTAssertFalse(offline.buttons["curve.edit.1"].exists)
        capture(offline, "Curves-offline")
    }
    private func revealImported(_ element: XCUIElement, app: XCUIApplication) {
        let scroll = app.scrollViews["curve.import.preview.scroll"]
        for _ in 0..<8 {
            if element.isHittable { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    func testImportedAICurveRemainsUnsentThroughBothReviewRoutes() {
        let app = launch("Light")
        app.buttons["Curve options"].tap(); app.buttons["Import curve"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "curve.import.json").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4)); field.tap()
        field.typeText(#"{"name":"Imported calm","bedtime":"22:00","wake":"07:00","points":{"22:00":74,"02:00":68,"07:00":78},"reasoning":"Local UI fixture"}"#)
        let review = app.buttons["curve.import.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 6))
        XCTAssertEqual(app.otherElements["curve.import.graph"].value as? String, "22:00 · 74°F, 02:00 · 68°F, 07:00 · 78°F")
        capture(app, "Curves-AI-import-preview")
        revealImported(review, app: app)
        review.tap()
        XCTAssertTrue(app.navigationBars["New curve"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Curve name"].value as? String, "Imported calm")
        capture(app, "Curves-AI-save-review")
        app.navigationBars.buttons["Cancel"].tap()
        revealImported(app.buttons["Use Now"], app: app)
        app.buttons["Use Now"].tap()
        XCTAssertTrue(app.navigationBars["Run once"].waitForExistence(timeout: 3))
        capture(app, "Curves-AI-run-review")
        app.navigationBars.buttons["Cancel"].tap()
        app.navigationBars.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["curve.edit.100"].exists)
        XCTAssertFalse(app.buttons["Stop run-once curve"].exists)
        XCTAssertTrue(app.buttons["curve.edit.1"].exists)
    }

}
