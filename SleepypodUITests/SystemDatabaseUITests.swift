import XCTest
import UIKit

@MainActor final class SystemDatabaseUITests: XCTestCase {
    func testNativeInventoryPagingAndExactFilter() {
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        let databases = app.buttons["system.databases"]
        reveal(databases, app: app); databases.tap()
        XCTAssertTrue(app.navigationBars["Databases"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["DEMO · simulated database inventory and rows"].exists)
        capture(app, "Databases-inventory")
        let table = app.buttons["database.table.sleepypod.automation_runs"]
        reveal(table, app: app); table.tap()
        let browse = app.buttons["database.browse"]
        reveal(browse, app: app); capture(app, "Databases-table-growth"); browse.tap()
        reveal(app.staticTexts["database.rowCount"], app: app)
        XCTAssertTrue(app.staticTexts["database.rowCount"].label.contains("23 matching rows"))
        reveal(app.buttons["database.column"], app: app); app.buttons["database.column"].tap(); app.buttons["side"].tap()
        reveal(app.textFields["database.filterValue"], app: app)
        app.textFields["database.filterValue"].tap(); app.textFields["database.filterValue"].typeText("left\n")
        reveal(app.staticTexts["database.rowCount"], app: app)
        XCTAssertTrue(app.staticTexts["database.rowCount"].label.contains("11 matching rows"))
        capture(app, "Databases-filtered-rows")
        let next = app.buttons["database.nextPage"]
        reveal(next, app: app); next.tap()
        reveal(app.staticTexts["database.rowCount"], app: app)
        XCTAssertTrue(app.staticTexts["database.rowCount"].label.contains("page 2"))
        capture(app, "Databases-second-page")
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<35 {
            if element.exists, element.isHittable, element.frame.midY > 120, element.frame.midY < app.frame.maxY - 70 { return }
            if element.exists, element.frame.midY < 120 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
