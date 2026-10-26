import XCTest

@MainActor final class BiometricReportsUITests: XCTestCase {
    func testTraceSelectionAndExactConfiguration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.biometricProfiles"], app)
        tap(app.buttons["profiles.backtests"], app); tap(app.buttons["backtests.exampleReports"], app)
        tap(app.buttons["reports.example.signal_replay"], app); tap(app.buttons["reports.numeric"], app)
        tap(app.buttons["reports.summaryMetric"], app); app.buttons["Breathing rate · breaths/min"].firstMatch.tap()
        capture(app, "Reports-selected-summary")
        back(to: "Evaluation report", app); tap(app.buttons["reports.numericTraces"], app)
        tap(app.buttons["traces.configuration"], app); app.buttons["Candidate"].firstMatch.tap()
        tap(app.buttons["traces.metric"], app); app.buttons["Breathing rate · breaths/min"].firstMatch.tap()
        reveal(app.otherElements["traces.numericChart"], app); capture(app, "Reports-selected-breathing-chart")
        tap(app.buttons["traces.references"], app)
        reveal(app.staticTexts["Reference records 0–0 of 0"], app); capture(app, "Reports-empty-reference-metric")
        back(to: "Evaluation report", app)
        tap(app.buttons["reports.stageTraces"], app)
        reveal(app.otherElements["traces.stageChart"], app); capture(app, "Reports-stage-chart")
        tap(app.buttons["traces.exactStages"], app)
        reveal(app.staticTexts["Configuration hash"].firstMatch, app); capture(app, "Reports-stage-intervals")
    }
    func testFrozenScoresTracesReferencesAndReportRelease() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.biometricProfiles"], app)
        tap(app.buttons["profiles.backtests"], app); tap(app.buttons["backtests.exampleReports"], app)
        capture(app, "Reports-examples")
        tap(app.buttons["reports.example.signal_replay"], app)
        XCTAssertTrue(app.staticTexts["reports.status"].waitForExistence(timeout: 5))
        capture(app, "Reports-overview")
        tap(app.buttons["reports.numeric"], app); capture(app, "Reports-numeric-summary")
        let night = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reports.night.")).firstMatch
        tap(night, app); capture(app, "Reports-night")
        tap(app.buttons["reports.score.default.heart_rate"], app)
        reveal(app.staticTexts["95th percentile absolute error"].firstMatch, app); capture(app, "Reports-numeric-errors")
        back(to: "Evaluation report", app)
        tap(app.buttons["reports.numericTraces"], app)
        reveal(app.otherElements["traces.numericChart"], app); capture(app, "Reports-recomputed-chart")
        tap(app.buttons["traces.references"], app)
        reveal(app.otherElements["traces.referenceChart"], app); capture(app, "Reports-reference-overlay")
        tap(app.buttons["traces.exactReferences"], app)
        reveal(app.staticTexts["Aggregation"].firstMatch, app); capture(app, "Reports-frozen-source")
        back(to: "Evaluation report", app)
        tap(app.buttons["reports.stageTraces"], app)
        reveal(app.otherElements["traces.stageChart"], app); capture(app, "Reports-stage-chart")
        tap(app.buttons["traces.exactStages"], app)
        reveal(app.staticTexts["Original start"].firstMatch, app); capture(app, "Reports-stage-intervals")
        back(to: "Evaluation report", app)
        tap(app.buttons["reports.stages"], app)
        let comparison = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reports.stageComparison.")).firstMatch
        tap(comparison, app); capture(app, "Reports-stage-agreement")
        tap(app.buttons["reports.confusion"], app)
        tap(app.buttons["Reference: Wake"].firstMatch, app)
        reveal(app.staticTexts["Predicted Deep"].firstMatch, app); capture(app, "Reports-confusion")
        back(to: "Evaluation report", app)
        tap(app.buttons["reports.resources"], app); capture(app, "Reports-processing-costs")
        tap(app.buttons["reports.resources"], app)
        tap(app.buttons["reports.numericPolicy"].firstMatch, app); capture(app, "Reports-frozen-policy")
        tap(app.buttons["reports.numericPolicy"].firstMatch, app)
        tap(app.buttons["reports.release"], app)
        let confirm = app.buttons["reports.confirmRelease"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["reports.released"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["reports.released"], app); capture(app, "Reports-released")
        back(to: "Example reports", app)
        tap(app.buttons["reports.example.signal_replay"], app)
        XCTAssertTrue(app.staticTexts["reports.released"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reports.numeric"].exists)
    }
    private func back(to title: String, _ app: XCUIApplication) {
        for _ in 0..<8 {
            if app.navigationBars[title].exists { return }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTFail("Could not return to \(title)")
    }
    private func tap(_ element: XCUIElement, _ app: XCUIApplication) {
        reveal(element, app); XCTAssertTrue(element.isEnabled)
        if element.elementType == .button, element.frame.height > app.frame.height * 0.7 {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 24)).tap()
        } else { element.tap() }
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
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
            let delta = !frame.isEmpty ? targetY - visible.midY : visible.height
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
