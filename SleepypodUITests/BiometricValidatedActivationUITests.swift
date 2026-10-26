import XCTest

@MainActor final class BiometricValidatedActivationUITests: XCTestCase {
    func testEvaluatedProfileReviewPreservesExactIdentityAndRefusesDemoEvidence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        tap(app.buttons["settings.biometricProfiles"], app)
        tap(app.buttons["profiles.backtests"], app); tap(app.buttons["backtests.exampleReports"], app)
        tap(app.buttons["reports.example.signal_replay"], app)
        tap(app.buttons["reports.validatedActivation"], app)
        XCTAssertTrue(app.navigationBars["Apply evaluated profile"].waitForExistence(timeout: 5))
        capture(app, "Validated-overview")
        tap(app.buttons["validated.selection"], app)
        reveal(app.staticTexts["Complete report hash"].firstMatch, app); capture(app, "Validated-exact-selection")
        tap(app.buttons["validated.selection"], app)
        tap(app.buttons["validated.boundary"], app)
        app.buttons["Immediate processing boundary"].firstMatch.tap()
        reveal(app.buttons["validated.boundary"], app)
        XCTAssertEqual(app.buttons["validated.boundary"].value as? String, "Immediate processing boundary")
        capture(app, "Validated-timing")
        tap(app.buttons["validated.review"], app)
        let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "synthetic examples")).firstMatch
        reveal(explanation, app); capture(app, "Validated-unavailable-evidence")
        reveal(app.buttons["validated.apply"], app)
        XCTAssertFalse(app.buttons["validated.apply"].isEnabled)
        XCTAssertFalse(app.buttons["profiles.retryExact"].exists)
        XCTAssertFalse(app.staticTexts["validated.saved"].exists)
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
