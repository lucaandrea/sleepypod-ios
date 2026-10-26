import XCTest

@MainActor final class BiometricObservationUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.biometricProfiles"], app)
        tap(app.buttons["profiles.observations"], app)
        XCTAssertTrue(app.navigationBars["Prospective observations"].waitForExistence(timeout: 5))
        return app
    }
    func testReviewScheduleStopAndInspectEmptyDemoRun() {
        let app = launch()
        capture(app, "Observation-list")
        tap(app.buttons["observations.schedule"], app)
        tap(app.buttons["observations.template"], app)
        app.buttons["Demo scheduling · no live worker"].firstMatch.tap()
        tap(app.textFields["observations.subject"], app); app.textFields["observations.subject"].typeText("Synthetic sleeper\n")
        tap(app.buttons["observations.candidate.default"], app)
        reveal(app.textFields["observations.start"], app); capture(app, "Observation-window")
        tap(app.buttons["observations.prepare"], app)
        reveal(app.staticTexts["observations.prepared"], app); capture(app, "Observation-prepared")
        tap(app.buttons["observations.submit"], app)
        tap(app.buttons["observations.inspectSaved"], app)
        reveal(app.staticTexts["Saved observations"], app); capture(app, "Observation-scheduled")
        tap(app.buttons["observations.stop"], app)
        let confirm = app.buttons["observations.confirmStop"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        reveal(app.staticTexts["observations.state"], app, up: false)
        XCTAssertEqual(app.staticTexts["observations.state"].label, "Stop recorded")
        capture(app, "Observation-stopped")
        tap(app.buttons["observations.report"], app)
        reveal(app.staticTexts["No observations were saved."].firstMatch, app); capture(app, "Observation-no-worker")
    }
    func testLiteralReportAndReferenceSnapshot() {
        let app = launch()
        tap(app.buttons["observations.run.60000000-0000-4000-8000-000000000001"], app)
        tap(app.buttons["observations.report"], app)
        reveal(app.staticTexts["observations.health"], app); capture(app, "Observation-health")
        reveal(app.staticTexts["Candidate coverage"].firstMatch, app); capture(app, "Observation-coverage")
        tap(app.buttons["observations.resources"], app)
        reveal(app.staticTexts["No worker resource receipt is available."].firstMatch, app); capture(app, "Observation-resources")
        tap(app.buttons["observations.resources"], app)
        tap(app.buttons["observations.compare"], app)
        tap(app.buttons["observations.exampleReference"], app)
        reveal(app.textFields["observations.referenceSource"], app, up: false); capture(app, "Observation-reference-input")
        tap(app.buttons["observations.compareReference"], app)
        reveal(app.staticTexts["observations.comparisonSnapshot"], app); capture(app, "Observation-comparison")
        reveal(app.staticTexts["Shared-timestamp MAE · candidate"].firstMatch, app); capture(app, "Observation-reference-scores")
        tap(app.textFields["observations.referenceSource"], app, up: false); app.textFields["observations.referenceSource"].typeText(" edited\n")
        XCTAssertFalse(app.staticTexts["observations.comparisonSnapshot"].exists)
    }
    private func tap(_ element: XCUIElement, _ app: XCUIApplication, up: Bool = true) {
        reveal(element, app, up: up); XCTAssertTrue(element.isEnabled)
        if element.elementType == .button, element.frame.height > app.frame.height * 0.7 {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 24)).tap()
        } else { element.tap() }
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, up: Bool = true) {
        for _ in 0..<100 {
            let scroll = app.scrollViews.firstMatch
            let surface = scroll.exists && scroll.isHittable ? scroll : app
            let bounds = surface.frame.intersection(app.frame), nav = app.navigationBars.firstMatch
            let top = nav.exists ? max(bounds.minY, nav.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 12))
            let frame = element.exists ? element.frame : .zero
            // Expanded SwiftUI disclosure buttons include their content in the accessibility frame.
            let targetY = element.exists && element.elementType == .button && frame.height > app.frame.height * 0.7 ? frame.minY + 24 : frame.midY
            if element.exists, element.isHittable {
                if frame.height <= visible.height ? visible.contains(frame) : visible.contains(CGPoint(x: frame.midX, y: targetY)) { return }
            }
            let delta = !frame.isEmpty ? targetY - visible.midY : (up ? visible.height : -visible.height)
            let distance = min(0.4, max(0.08, abs(delta) / max(bounds.height, 1)))
            let direction = delta >= 0 ? 1.0 : -1.0
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
