import XCTest

@MainActor final class BedroomDevicesUITests: XCTestCase {
    func testRoomSettingsShowsDevicesDirectlyAndDistinguishesCachedValues() {
        continueAfterFailure = false
        let app = launch(route: "allsettings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        reveal(app.buttons["settings.room"], in: app); app.buttons["settings.room"].tap()
        XCTAssertTrue(app.navigationBars["Room sensors"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["SYNTHETIC EXAMPLE"].waitForExistence(timeout: 5))
        capture(app, name: "Bedroom-climate-and-bedside")
        for name in ["Fixture left bedside", "Fixture right bedside", "Fixture air monitor", "Fixture purifier", "Fixture scent diffuser"] {
            let item = app.scrollViews["room.screen"].staticTexts[name].firstMatch
            reveal(item, in: app); XCTAssertTrue(item.exists)
        }
        capture(app, name: "Bedroom-device-states")
        let cached = source("monitor-particles", in: app)
        reveal(cached, in: app)
        XCTAssertTrue(cached.label.contains("1 µg/m³"), cached.label)
        XCTAssertTrue(cached.label.contains("Cached report · freshness unknown"), cached.label)
        XCTAssertTrue(cached.label.contains("not a live measurement"), cached.label)
        capture(app, name: "Bedroom-cached-value-clearly-labelled")
        let details = app.buttons["room.bedroom"]
        reveal(details, in: app); details.tap()
        XCTAssertTrue(app.navigationBars["Bedroom devices"].waitForExistence(timeout: 5))
    }
    func testTemperatureCardShowsDeviceReadingsWithoutRequiringComfortSelection() {
        continueAfterFailure = false
        let app = launch(route: "")
        let temperature = source("left-temperature", in: app)
        reveal(temperature, in: app)
        XCTAssertTrue(temperature.label.contains("76 °F"), temperature.label)
        let particles = source("monitor-particles", in: app)
        reveal(particles, in: app)
        XCTAssertTrue(particles.label.contains("1 µg/m³"), particles.label)
        XCTAssertTrue(particles.label.contains("freshness unknown"), particles.label)
        capture(app, name: "Temperature-room-device-readings")
    }
    func testRoomSensorValuesAtLargestAccessibilityTextSize() {
        continueAfterFailure = false
        let app = launch(route: "allsettings", largeText: true)
        reveal(app.buttons["settings.room"], in: app); app.buttons["settings.room"].tap()
        let reading = source("left-temperature", in: app)
        reveal(reading, in: app)
        XCTAssertTrue(reading.label.contains("76 °F"), reading.label)
        XCTAssertLessThanOrEqual(reading.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(reading.frame.minX, app.frame.minX)
        capture(app, name: "Room-readings-accessibility-size")
    }
    private func launch(route: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", route, "-uiBedroomFixture", "YES", "-temperatureFormat", "fahrenheit",
                               "-UIPreferredContentSizeCategoryName", largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }
    private func source(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let room = app.scrollViews["room.screen"]
        let surface = room.exists ? room : app.scrollViews.firstMatch
        return surface.descendants(matching: .any).matching(identifier: "bedroom.source.\(identifier)").firstMatch
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let roomBar = app.navigationBars["Room sensors"]
        let settingsBar = app.navigationBars["Settings"]
        let bar = roomBar.exists ? roomBar : settingsBar.exists ? settingsBar : app.navigationBars.firstMatch
        let top = bar.exists ? bar.frame.maxY + 12 : app.frame.minY + 120
        let viewport = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: app.frame.maxY - top - 100)
        for _ in 0..<24 {
            let frame = element.exists ? element.frame : .zero
            if element.exists, element.isHittable, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            let room = app.scrollViews["room.screen"]
            let surface = room.exists ? room : app.scrollViews.firstMatch
            let upward = !element.exists || frame.midY >= viewport.midY
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: upward ? 0.78 : 0.30))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: upward ? 0.30 : 0.78))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        print(app.debugDescription)
        XCTFail("Unable to reach the requested room reading")
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
