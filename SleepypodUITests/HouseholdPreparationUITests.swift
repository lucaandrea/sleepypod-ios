import XCTest

@MainActor final class HouseholdPreparationUITests: XCTestCase {
    func testUnassignedMemberSeesOnlyPrivatePreparationAndReachableDraftFields() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--household-fixture", "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", "Dark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["household.assignment"].label, "No bed side assigned")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["Invite another person"].exists)
        capture(app, "Personal-member-preparation")
        app.buttons["Comfort preferences"].tap()
        XCTAssertTrue(app.navigationBars["Comfort preferences"].waitForExistence(timeout: 5))
        capture(app, "Personal-comfort-draft")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Weekly routine drafts"].tap()
        XCTAssertTrue(app.staticTexts["household.routines.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["household.routines.status"].label, "Draft only")
        capture(app, "Personal-weekly-drafts")
        let sunday = app.buttons["household.night.sunday"]
        for _ in 0..<6 where !sunday.isHittable { app.swipeUp() }
        XCTAssertTrue(sunday.isHittable); sunday.tap()
        XCTAssertTrue(app.navigationBars["Sunday draft"].waitForExistence(timeout: 5))
        capture(app, "Personal-night-draft")
        app.terminate()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
