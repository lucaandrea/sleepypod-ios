import XCTest
import UIKit

@MainActor final class HomeFeedbackUITests: XCTestCase {
    func testAnalysisShowsHistoryAndHealthAccessBeforeModelDetails() {
        checkAnalysis(largeText: false)
    }
    func testAnalysisRemainsUsableWithAccessibilityText() {
        checkAnalysis(largeText: true)
    }
    func testSleepShortcutsRecipesAndAppLibrary() {
        let app = launch()
        let link = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Home & Shortcuts")).firstMatch
        reveal(link, app); link.tap()
        let library = app.buttons["shortcuts.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        capture(app, "Sleep-shortcuts-library")
        let recipe = app.buttons["Tomorrow starts earlier"]
        reveal(recipe, app); recipe.tap()
        let detail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Add Change next bed alarm'")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 3)); reveal(detail, app)
        capture(app, "Sleep-shortcuts-alarm-recipe")
        reveal(library, app); library.tap()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        XCTAssertTrue(shortcuts.wait(for: .runningForeground, timeout: 12))
        let welcome = shortcuts.buttons["Continue"]
        if welcome.waitForExistence(timeout: 3) { welcome.tap() }
        XCTAssertTrue(shortcuts.staticTexts["Next bed alarm"].waitForExistence(timeout: 20), "The app's real actions must be discoverable in Shortcuts")
        if !shortcuts.staticTexts["Next bed alarm"].isHittable,
           let appRow = shortcuts.staticTexts.matching(identifier: "sleepypod").allElementsBoundByIndex.first(where: \.isHittable) {
            appRow.tap()
        }
        if !shortcuts.staticTexts["Next bed alarm"].isHittable,
           let sidebar = shortcuts.buttons.matching(identifier: "Hide Sidebar").allElementsBoundByIndex.first(where: \.isHittable) {
            sidebar.tap()
        }
        XCTAssertTrue(shortcuts.staticTexts["Next bed alarm"].isHittable)
        capture(shortcuts, "Sleep-shortcuts-system-handoff")
    }
    func testDiscoveredConnectionAddressIsPrefilled() {
        let app = launch(extra: ["-podURL", "", "-podIPAddress", "192.168.1.88"])
        let link = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Pod connection")).firstMatch
        reveal(link, app); link.tap()
        let address = app.textFields["Pod controller address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertEqual(address.value as? String, "http://192.168.1.88:3000")
        XCTAssertTrue(app.secureTextFields["connection.key"].exists)
        capture(app, "Connection-prefilled")
    }
    private func checkAnalysis(largeText: Bool) {
        let app = launch(extra: largeText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        let link = app.buttons["settings.analysis"]
        reveal(link, app); link.tap()
        let refresh = app.buttons["analysis.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["history records"].exists)
        XCTAssertTrue(app.otherElements["Bed record coverage by month"].exists)
        capture(app, largeText ? "Analysis-accessibility-history" : "Analysis-history")
        let health = app.buttons["analysis.health"]
        reveal(health, app); capture(app, largeText ? "Analysis-accessibility-health" : "Analysis-health")
        health.tap()
        XCTAssertTrue(app.navigationBars["Apple Health"].waitForExistence(timeout: 5))
    }
    private func launch(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", "allsettings", "-userDefaultSide", "left", "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"] + extra
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15)); return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<35 {
            let bounds = app.frame.insetBy(dx: 12, dy: 100)
            // Accessibility rows can exceed the viewport; keep their tappable center visible.
            if element.exists, element.isHittable,
               bounds.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let upward = !element.exists || element.frame.midY > bounds.midY
            app.coordinate(withNormalizedOffset: .init(dx: 0.96, dy: upward ? 0.75 : 0.30))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.96, dy: upward ? 0.35 : 0.70)))
        }
        capture(app, "Unreachable-control")
        XCTFail("Could not reach \(element.identifier): \(element.frame)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
