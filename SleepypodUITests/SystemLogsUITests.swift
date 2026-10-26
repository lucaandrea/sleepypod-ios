import XCTest
import UIKit

@MainActor final class SystemLogsUITests: XCTestCase {
    func testSourcePrioritySearchCopyAndExport() {
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        reveal(app.buttons["system.logs"], app: app); app.buttons["system.logs"].tap()
        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["DEMO · simulated service logs"].exists)
        app.buttons["logs.follow"].tap()
        XCTAssertEqual(app.buttons["logs.follow"].label, "Follow")
        reveal(app.buttons["logs.source"], app: app); app.buttons["logs.source"].tap()
        let environment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Environment Monitor")).firstMatch
        XCTAssertTrue(environment.waitForExistence(timeout: 3)); environment.tap()
        reveal(app.buttons["logs.level"], app: app); app.buttons["logs.level"].tap()
        app.buttons["Warn"].tap()
        let count = app.staticTexts["logs.count"]
        reveal(count, app: app)
        XCTAssertEqual(count.label, "2 matching lines · newest first")
        capture(app, "Logs-priority-filter")
        let search = app.textFields["logs.search"]
        reveal(search, app: app); search.tap(); search.typeText("stale\n")
        reveal(app.buttons["logs.copy"], app: app); app.buttons["logs.copy"].tap()
        XCTAssertEqual(app.buttons["logs.copy"].label, "Copied")
        capture(app, "Logs-search-controls")
        reveal(count, app: app)
        XCTAssertEqual(count.label, "1 matching line · newest first")
        reveal(app.staticTexts["[WARN] Simulated sensor sample is stale"], app: app)
        capture(app, "Logs-matching-line")
        reveal(app.buttons["logs.export"], app: app); app.buttons["logs.export"].tap()
        // iOS 27 exposes the document picker's Cancel affordance as Other, not Button.
        let cancel = app.descendants(matching: .any).matching(identifier: "Cancel").firstMatch
        guard cancel.waitForExistence(timeout: 20) else {
            capture(app, "Logs-export-picker-missing")
            XCTFail("The system export picker did not become available: \(app.debugDescription)")
            return
        }
        capture(app, "Logs-export-picker")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<40 {
            let content = app.scrollViews["logs.content"]
            let surface = content.exists ? content : app
            let visible = surface.frame.intersection(app.frame).insetBy(dx: 0, dy: 50)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = element.exists && element.frame.midY < visible.minY
            let distance = min(150, visible.height * 0.3)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY + (down ? distance : -distance)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // Let the native text transition finish before retaining visual evidence.
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
