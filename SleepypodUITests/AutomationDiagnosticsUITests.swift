import XCTest
import UIKit

@MainActor final class AutomationDiagnosticsUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "autopilot", "-uiAutomationScenario", scenario, "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.buttons["automation.new"].waitForExistence(timeout: 15)); return app
    }
    func testRecordedOutcomesMinuteInspectionLiveThresholdsFiltersAndPaging() {
        let app = launch("diagnostics")
        app.buttons["Diagnostics"].tap()
        let firstRule = app.buttons["diagnostics.edit.1"]; reveal(firstRule, app)
        capture(app, "Diagnostics-rule")
        reveal(app.staticTexts["Last evaluated"].firstMatch, app); capture(app, "Diagnostics-statistics")
        let inspect = app.buttons["Inspect minute"].firstMatch; reveal(inspect, app); inspect.tap()
        let decrement = app.steppers["diagnostics.minute"].firstMatch.buttons["diagnostics.minute-Decrement"]; reveal(decrement, app)
        decrement.tap(); capture(app, "Diagnostics-minute")
        let signals = app.buttons["Live signals and thresholds"].firstMatch; reveal(signals, app); signals.tap()
        reveal(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Comparison >")).firstMatch, app)
        capture(app, "Diagnostics-live-threshold")
        let filter = app.buttons["diagnostics.filter.1"]; reveal(filter, app); filter.tap()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Missing ·")).firstMatch.tap()
        reveal(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "An expected interval")).firstMatch, app)
        capture(app, "Diagnostics-missing")
        reveal(filter, app); filter.tap(); app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Fired ·")).firstMatch.tap()
        capture(app, "Diagnostics-fired")
        let more = app.buttons["diagnostics.more.2"]; reveal(more, app); capture(app, "Diagnostics-log-page")
        more.tap(); capture(app, "Diagnostics-log-expanded")
        reveal(firstRule, app); firstRule.tap()
        XCTAssertTrue(app.textFields["automation.name"].waitForExistence(timeout: 5)); capture(app, "Diagnostics-edit-rule")
        app.navigationBars.buttons["Cancel"].tap()
    }
    func testLostCreateKeepsDraftAndReadsSavedResultWithoutResubmitting() {
        let app = launch("lost-create")
        app.buttons["automation.new"].tap()
        let name = app.textFields["automation.name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "New automation".count) + "Recovered native draft")
        let save = app.buttons["automation.save"]; XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["automation.saveError"].waitForExistence(timeout: 5)); XCTAssertFalse(save.isEnabled)
        let readback = app.buttons["automation.readback"]; reveal(readback, app); capture(app, "Diagnostics-uncertain-save")
        readback.tap(); XCTAssertTrue(app.navigationBars["Edit automation"].waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled); capture(app, "Diagnostics-readback")
        reveal(name, app, searchUp: true); XCTAssertEqual(name.value as? String, "Recovered native draft")
        app.navigationBars.buttons["Cancel"].tap()
        let recovered = app.buttons["automation.edit.3"]; reveal(recovered, app); capture(app, "Diagnostics-recovered-rule")
        XCTAssertFalse(app.buttons["automation.edit.4"].exists)
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, searchUp: Bool = false) {
        for _ in 0..<60 {
            let editor = app.collectionViews["automation.editor"]
            let scroll = editor.exists ? editor : app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height } ?? app.collectionViews.firstMatch
            let bounds = scroll.frame.intersection(app.frame), top = max(bounds.minY + 12, app.navigationBars.firstMatch.frame.maxY + 12)
            let frame = element.exists ? element.frame : .zero
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 24))
            if element.exists, element.isHittable, visible.contains(frame) || (frame.height > visible.height && frame.minY >= visible.minY && visible.intersects(frame)) { return }
            let direction = frame.isEmpty ? (searchUp ? -1.0 : 1.0) : frame.midY >= visible.midY ? 1.0 : -1.0
            let distance = min(0.45, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
