import XCTest

@MainActor
final class UnifiedNavigationTests: XCTestCase {
    private func launch(_ appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "", "-tempControl", "dial"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Temp"].waitForExistence(timeout: 10))
        return app
    }

    func testOriginalNavigationAndContextualEditors() {
        let app = launch()
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        for removed in ["Tonight", "Autopilot", "Home", "More"] { XCTAssertFalse(app.tabBars.buttons[removed].exists) }
        attach(app, name: "01-Temp-dark")
        app.tabBars.buttons["Schedule"].tap()
        XCTAssertTrue(app.staticTexts["Schedule active"].waitForExistence(timeout: 10))
        attach(app, name: "02-Schedule-dark")
        app.buttons["Schedule options"].tap()
        app.buttons["Next alarm"].tap()
        XCTAssertTrue(app.navigationBars["Next alarm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change time"].waitForExistence(timeout: 5))
        attach(app, name: "03-Next-alarm-dark")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Sleep"].tap()
        XCTAssertTrue(app.buttons["Week"].waitForExistence(timeout: 10))
        attach(app, name: "04-Sleep-dark")
        app.buttons["Sleep options"].tap()
        app.buttons["Morning check-in"].tap()
        XCTAssertTrue(app.navigationBars["Morning check-in"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save check-in"].waitForExistence(timeout: 5))
        attach(app, name: "05-Check-in-dark")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Sleep options"].tap()
        app.buttons["Personal reports"].tap()
        XCTAssertTrue(app.navigationBars["Personal reports"].waitForExistence(timeout: 5))
        attach(app, name: "06-Personal-reports-dark")
    }

    func testBasePreviewAndSettingsUseSleepypodComponents() {
        let app = launch("Light")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Bed position"].waitForExistence(timeout: 5))
        app.buttons["Bed position"].tap()
        XCTAssertTrue(app.navigationBars["Bed position"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Show mattress"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.navigationBars["Bed position"].frame.minY, 160, "Bed controls should expand the sheet")
        attach(app, name: "07-Bed-position-light")
        app.switches["Show mattress"].tap()
        attach(app, name: "08-Bed-frame-light")
        for _ in 0..<5 where !app.buttons["Stop"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["base.move.both"].exists)
        XCTAssertTrue(app.buttons["base.move.both"].isEnabled, "Demo movement stays in the local simulation")
        XCTAssertTrue(app.navigationBars.buttons["Stop"].isEnabled)
        attach(app, name: "09-Bed-controls-light")
    }

    func testPersonalFeaturesRemainReachableFromSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", "Dark",
                               "-healthSyncEnabled", "NO", "-uiRoute", "allsettings", "-tempControl", "dial"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        for title in ["Personal comfort", "Routine editor", "Health history", "Pod Health export", "Morning check-in", "Sleep coach", "Models", "Recorded episodes", "Home & Shortcuts"] {
            let link = app.buttons[title].firstMatch
            for _ in 0..<12 where !link.isHittable { app.swipeUp() }
            XCTAssertTrue(link.isHittable, "Missing settings entry: \(title)")
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), title)
            attach(app, name: "Feature-" + title)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
