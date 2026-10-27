import XCTest

@MainActor final class BedroomDevicesUITests: XCTestCase {
    func testFiveSyntheticDevicesAndUnavailableParticleReading() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings", "-uiBedroomFixture", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        reveal(app.buttons["settings.room"], in: app); app.buttons["settings.room"].tap()
        XCTAssertTrue(app.buttons["room.bedroom"].waitForExistence(timeout: 5)); app.buttons["room.bedroom"].tap()
        XCTAssertTrue(app.navigationBars["Bedroom devices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["SYNTHETIC EXAMPLE"].waitForExistence(timeout: 5))
        capture(app, name: "Bedroom-climate-and-bedside")
        for name in ["Fixture left bedside", "Fixture right bedside", "Fixture air monitor", "Fixture purifier", "Fixture scent diffuser"] {
            let item = app.staticTexts[name]
            reveal(item, in: app); XCTAssertTrue(item.exists)
        }
        capture(app, name: "Bedroom-device-states")
        let cached = app.staticTexts["Cached · not a live measurement"]
        reveal(cached, in: app); XCTAssertTrue(cached.exists)
        capture(app, name: "Bedroom-cached-reading-withheld")
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<35 {
            if element.exists, element.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            if element.exists, element.frame.midY < scroll.frame.midY { scroll.swipeDown(velocity: .slow) }
            else { scroll.swipeUp(velocity: .slow) }
        }
        XCTFail("Unable to reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
