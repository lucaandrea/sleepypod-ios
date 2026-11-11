import XCTest
import UIKit

@MainActor final class NightExplanationUITests: XCTestCase {
    func testNightHistorySourcesAndFiltering() { verify(large: false) }
    func testNightHistoryAtMaximumTextSize() { verify(large: true) }
    func testUnavailableNightKeepsRecoveryAndNoOldEvidence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", "temp", "-temperatureFormat", "fahrenheit", "-temperatureLayout", "cards",
                               "-household.personalWorkspaceActive", "NO", "-uiNightUnavailable", "YES", "-appearance", "Dark"]
        app.launch()
        let link = app.buttons["tonight.nightHistory"]; reveal(link, app); link.tap()
        let unavailable = app.staticTexts["night.unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertTrue(unavailable.label.contains("Night evidence is unavailable"))
        XCTAssertFalse(app.staticTexts["night.window"].exists)
        XCTAssertTrue(app.buttons["night.refresh"].isEnabled)
        capture("Night-unavailable"); app.terminate()
    }
    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", "temp", "-temperatureFormat", "fahrenheit", "-temperatureLayout", "cards",
                               "-household.personalWorkspaceActive", "NO", "-uiNightUnavailable", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let link = app.buttons["tonight.nightHistory"]; reveal(link, app); link.tap()
        XCTAssertTrue(app.navigationBars["What happened overnight?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Practice · simulated night history"].waitForExistence(timeout: 10))
        capture(large ? "Night-large-overview" : "Night-overview")
        let window = app.staticTexts["night.window"]; reveal(window, app)
        XCTAssertTrue(window.label.contains("Missing records are unknown"))
        capture(large ? "Night-large-window" : "Night-window")
        let chart = app.descendants(matching: .any).matching(identifier: "night.temperatures").firstMatch
        revealChart(chart, app); capture(large ? "Night-large-chart" : "Night-chart")
        let filter = app.buttons["night.filter"]
        for title in ["Controller requests", "Automation rules", "All recorded events", "Personal Autopilot"] {
            reveal(filter, app); filter.tap(); app.buttons[title].tap()
            XCTAssertEqual(filter.value as? String, title)
            XCTAssertGreaterThanOrEqual(filter.frame.height, 44)
        }
        let held = app.staticTexts["Personal adaptation held back · 69°F"].firstMatch
        reveal(held, app); XCTAssertTrue(held.exists)
        XCTAssertFalse(app.staticTexts["Temperature request acknowledged · 70°F"].exists)
        capture(large ? "Night-large-events" : "Night-events")
        let room = app.buttons["night.room"]; reveal(room, app); room.tap()
        let cached = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "measurement time not supplied")).firstMatch
        reveal(cached, app); XCTAssertTrue(cached.label.contains("cached"))
        capture(large ? "Night-large-room" : "Night-room")
        let sources = app.buttons["night.sources"]; reveal(sources, app); sources.tap()
        let attribution = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "House actions are not yet connected")).firstMatch
        reveal(attribution, app); capture(large ? "Night-large-sources" : "Night-sources")
        XCTAssertFalse(app.buttons["Apply"].exists); XCTAssertFalse(app.buttons["Start"].exists)
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let container = app.scrollViews.firstMatch
        for _ in 0..<24 {
            let viewport = container.frame.intersection(app.frame).insetBy(dx: 8, dy: 32)
            let frame = element.exists ? element.frame : .zero
            if frame.height > 0, element.isHittable, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            let downward = !frame.isEmpty && frame.midY < viewport.minY
            // The center of Tonight contains the temperature dial; scroll only in the content margin.
            let start = container.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: downward ? 0.2 : 0.8))
            let end = container.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: downward ? 0.8 : 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        capture("Night-unreachable")
        XCTFail("Could not reach \(element.identifier); element: \(element.frame), app: \(app.frame), hittable: \(element.isHittable)")
    }
    // A centered AX element can still be clipped. Keep both chart edges inside the viewport.
    private func revealChart(_ chart: XCUIElement, _ app: XCUIApplication) {
        reveal(chart, app)
        for _ in 0..<8 {
            let bounds = chart.frame
            let tablet = UIDevice.current.userInterfaceIdiom == .pad
            let top = app.frame.minY + (tablet ? 150 : 125), bottom = app.frame.maxY - (tablet ? 32 : 90)
            if bounds.minY >= top && bounds.maxY <= bottom { return }
            let shift = bounds.minY < top ? top - bounds.minY : bottom - bounds.maxY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: max(-220, min(220, shift))))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("The complete temperature chart was not visible for capture")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
