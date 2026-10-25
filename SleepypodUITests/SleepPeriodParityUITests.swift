import XCTest

@MainActor final class SleepPeriodParityUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", "Dark", "-healthSyncEnabled", "NO", "-uiRoute", route]
        app.launch(); XCTAssertTrue(app.buttons["Sleep options"].waitForExistence(timeout: 15)); return app
    }
    private func show(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<20 {
            if element.isHittable { break }
            let up = element.frame.midY > app.frame.midY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: up ? 0.70 : 0.35))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: up ? 0.35 : 0.70))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testWeekSummariesAndNightDrillIn() {
        let app = launch("week")
        XCTAssertTrue(app.staticTexts["WEEK AVERAGES"].waitForExistence(timeout: 10))
        capture(app, "Sleep-week-summary")
        show(app.staticTexts["VITALS BY NIGHT"], in: app); capture(app, "Sleep-week-vitals")
        let open = app.buttons["sleep.openWeekNight"]; show(open, in: app); open.tap()
        XCTAssertTrue(app.buttons["sleep.editTimes"].waitForExistence(timeout: 8))
    }
    func testMonthCalendarAndNightList() {
        let app = launch("month")
        XCTAssertTrue(app.staticTexts["MONTH SUMMARY"].waitForExistence(timeout: 10)); capture(app, "Sleep-month-calendar")
        show(app.staticTexts["AVERAGE BY WEEK"], in: app); capture(app, "Sleep-month-weeks")
        let night = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sleep.monthNight.'")).firstMatch
        show(night, in: app); capture(app, "Sleep-month-nights"); night.tap()
        XCTAssertTrue(app.buttons["sleep.editTimes"].waitForExistence(timeout: 8))
    }
}
