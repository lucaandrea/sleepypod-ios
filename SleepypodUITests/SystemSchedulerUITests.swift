import XCTest
import UIKit

@MainActor final class SystemSchedulerUITests: XCTestCase {
    func testNightInspectionAndJobFilters() {
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        reveal(app.buttons["system.scheduler"], app: app); app.buttons["system.scheduler"].tap()
        XCTAssertTrue(app.navigationBars["Scheduler"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["DEMO · simulated scheduler jobs"].exists)
        app.navigationBars["Scheduler"].swipeUp()
        reveal(app.buttons["scheduler.night"], app: app); capture(app, "Scheduler-summary")
        let slider = app.sliders["scheduler.inspect"]
        reveal(slider, app: app); slider.adjust(toNormalizedSliderPosition: 0.45)
        XCTAssertTrue(app.staticTexts["scheduler.inspectedTime"].exists)
        capture(app, "Scheduler-targets")
        reveal(app.buttons["scheduler.night"], app: app); app.buttons["scheduler.night"].tap()
        let second = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Nov 1")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 3)); second.tap()
        reveal(app.buttons["scheduler.allJobs"], app: app); app.buttons["scheduler.allJobs"].tap()
        XCTAssertTrue(app.navigationBars["All jobs"].waitForExistence(timeout: 5))
        let search = app.textFields["scheduler.search"]
        reveal(search, app: app); search.tap(); search.typeText("prime\n")
        reveal(app.staticTexts["scheduler.jobCount"], app: app)
        XCTAssertEqual(app.staticTexts["scheduler.jobCount"].label, "1 matching job")
        capture(app, "Scheduler-job-filter")
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<40 {
            let content = app.scrollViews["scheduler.jobsContent"].exists ? app.scrollViews["scheduler.jobsContent"] : app.scrollViews["scheduler.content"]
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
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
