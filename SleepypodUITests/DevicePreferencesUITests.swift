import XCTest
import UIKit

@MainActor final class DevicePreferencesUITests: XCTestCase {
    func testDeviceTimesLEDAndSensorSource() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch()
        let route = app.buttons["settings.device"]
        reveal(route, app: app); route.tap()
        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 5))
        capture(app, "Device-pod")
        let timezone = app.buttons["devicePreferences.timezone"]
        reveal(timezone, app: app); timezone.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3)); search.tap(); search.typeText("Paris")
        app.buttons["Europe/Paris"].tap()
        XCTAssertTrue(timezone.label.contains("Europe/Paris"))
        let clock = app.buttons["devicePreferences.timeFormat"]
        reveal(clock, app: app); clock.tap(); app.buttons["24-hour"].tap()
        let cap = app.switches["devicePreferences.powerCap"]
        reveal(cap, app: app); cap.tap(); XCTAssertEqual(cap.value as? String, "0")
        capture(app, "Device-power")
        let prime = app.switches["devicePreferences.prime"]
        reveal(prime, app: app); prime.tap(); XCTAssertEqual(prime.value as? String, "1")
        XCTAssertTrue(app.datePickers["devicePreferences.primeTime"].exists)
        capture(app, "Device-maintenance")
        let night = app.switches["devicePreferences.ledNight"]
        reveal(night, app: app); night.tap(); XCTAssertEqual(night.value as? String, "1")
        let brightness = app.sliders["devicePreferences.nightBrightness"]
        reveal(brightness, app: app); brightness.adjust(toNormalizedSliderPosition: 0.25)
        capture(app, "Device-led")
        let save = app.buttons["devicePreferences.save"]
        reveal(save, app: app); XCTAssertTrue(save.isEnabled); save.tap()
        let receipt = app.staticTexts["devicePreferences.receipt"]
        reveal(receipt, app: app); XCTAssertEqual(receipt.label, "Device settings saved.")
        capture(app, "Device-saved")
        let source = app.staticTexts["devicePreferences.sourceStatus"]
        reveal(source, app: app); XCTAssertEqual(source.label, "Live")
        capture(app, "Device-sensor-source")
        reveal(timezone, app: app); XCTAssertTrue(timezone.label.contains("Europe/Paris"))
        reveal(cap, app: app); XCTAssertEqual(cap.value as? String, "0")
        let restart = app.buttons["devicePreferences.restart"]
        reveal(restart, app: app); XCTAssertTrue(restart.isEnabled); restart.tap()
        let confirm = app.buttons["Restart service"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        capture(app, "Device-restart-review"); confirm.tap()
        let restartReceipt = app.staticTexts["devicePreferences.restartReceipt"]
        reveal(restartReceipt, app: app); XCTAssertTrue(restartReceipt.label.contains("Simulated restart requested"))
        XCTAssertFalse(restart.isEnabled)
        capture(app, "Device-restart-requested")
        let reconnect = app.buttons["devicePreferences.reload"]
        reveal(reconnect, app: app); reconnect.tap()
        reveal(restartReceipt, app: app); XCTAssertEqual(restartReceipt.label, "The controller responded to reconnect.")
        XCTAssertTrue(restart.isEnabled)
        capture(app, "Device-reconnected")
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<55 {
            let scroll = app.scrollViews["devicePreferences.content"]
            let surface = scroll.exists ? scroll : app
            let bounds = surface.frame.intersection(app.frame)
            let navigation = app.navigationBars.firstMatch
            let top = navigation.exists ? max(bounds.minY, navigation.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 10))
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let upward = !(element.exists && element.frame.midY < visible.minY)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upward ? 0.70 : 0.35))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upward ? 0.35 : 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Device setting could not be reached")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
