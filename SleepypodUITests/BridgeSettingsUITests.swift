import XCTest
import UIKit

@MainActor final class BridgeSettingsUITests: XCTestCase {
    func testHomeKitBridgeStateAndReviewedReset() {
        let app = launch()
        let route = app.buttons["settings.homekitBridge"]
        reveal(route, app: app); route.tap()
        let enabled = app.switches["homekit.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        reveal(enabled, app: app); enabled.tap()
        waitForValue("0", on: enabled)
        capture(app, "HomeKit-disabled")
        enabled.tap(); waitForValue("1", on: enabled)
        let reset = app.buttons["homekit.reset"]
        reveal(reset, app: app); reset.tap()
        XCTAssertTrue(app.buttons["Reset pairing"].waitForExistence(timeout: 3))
        dismissReview(app)
        XCTAssertFalse(app.staticTexts["homekit.setupCode"].exists)
        reset.tap(); capture(app, "HomeKit-reset-review")
        app.buttons["Reset pairing"].firstMatch.tap()
        let code = app.staticTexts["homekit.setupCode"]
        reveal(code, app: app)
        XCTAssertEqual(code.label, "031-45-154")
        capture(app, "HomeKit-pairing")
        let pairingImage = app.images["homekit.qrCode"]
        reveal(pairingImage, app: app)
        for _ in 0..<5 {
            let viewport = app.scrollViews["homekit.content"].frame.intersection(app.frame)
            if pairingImage.frame.maxY < viewport.maxY - 20 { break }
            app.scrollViews["homekit.content"].swipeUp(velocity: .slow)
        }
        XCTAssertTrue(pairingImage.exists)
        XCTAssertLessThan(pairingImage.frame.maxY, app.frame.maxY - 10)
        capture(app, "HomeKit-pairing-QR")
        let receipt = app.staticTexts["homekit.receipt"]
        reveal(receipt, app: app)
        XCTAssertTrue(receipt.label.contains("Remove the old bridge"))
        capture(app, "HomeKit-reset-receipt")
    }
    func testMQTTDraftValidationConnectionTestAndSave() {
        let app = launch()
        let route = app.buttons["settings.mqtt"]
        reveal(route, app: app); route.tap()
        XCTAssertTrue(app.navigationBars["MQTT"].waitForExistence(timeout: 5))
        capture(app, "MQTT-status")
        let prefix = app.textFields["mqtt.topicPrefix"]
        reveal(prefix, app: app); prefix.tap()
        let existing = prefix.value as? String ?? ""
        prefix.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "bedroom/pod")
        XCTAssertEqual(prefix.value as? String, "bedroom/pod")
        app.toolbars.buttons["Done"].firstMatch.tap()
        let test = app.buttons["mqtt.test"]
        reveal(test, app: app); test.tap()
        let result = app.staticTexts["mqtt.testResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Settings have not been saved"))
        capture(app, "MQTT-test")
        let save = app.buttons["mqtt.save"]
        reveal(save, app: app); XCTAssertTrue(save.isEnabled); save.tap()
        let receipt = app.staticTexts["mqtt.saveReceipt"]
        reveal(receipt, app: app)
        XCTAssertTrue(receipt.label.contains("Configuration saved"))
        capture(app, "MQTT-saved")
        let tls = app.switches["mqtt.tls"]
        reveal(tls, app: app); tls.tap(); waitForValue("1", on: tls)
        let issue = app.staticTexts["TLS requires mqtts:// or wss:// in the broker URL."]
        reveal(issue, app: app); capture(app, "MQTT-TLS-validation")
        reveal(save, app: app); XCTAssertFalse(save.isEnabled)
    }
    func testNetworkChangesRequireReviewAndShowReportedState() {
        let app = launch()
        let route = app.buttons["settings.network"]
        reveal(route, app: app); route.tap()
        let internet = app.switches["network.internet"]
        XCTAssertTrue(internet.waitForExistence(timeout: 5))
        reveal(internet, app: app); waitForValue("1", on: internet)
        internet.tap(); XCTAssertTrue(app.buttons["Block internet"].waitForExistence(timeout: 3)); capture(app, "Network-review")
        dismissReview(app); waitForValue("1", on: internet)
        internet.tap(); app.buttons["Block internet"].firstMatch.tap()
        waitForValue("0", on: internet)
        let receipt = app.staticTexts["network.receipt"]
        reveal(receipt, app: app)
        XCTAssertTrue(receipt.label.contains("confirmed local-only"))
        capture(app, "Network-local-only")
        reveal(internet, app: app); internet.tap(); app.buttons["Allow internet"].firstMatch.tap()
        waitForValue("1", on: internet)
        reveal(receipt, app: app); XCTAssertTrue(receipt.label.contains("internet access is allowed"))
        capture(app, "Network-internet-allowed")
    }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance,
                               "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<35 {
            let scroll = ["homekit.content", "mqtt.content", "network.content"].map { app.scrollViews[$0] }.first { $0.exists }
            let surface = scroll ?? app
            let visible = surface.frame.intersection(app.frame)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            if element.exists && element.frame.midY < visible.minY { surface.swipeDown(velocity: .slow) }
            else { surface.swipeUp(velocity: .slow) }
        }
        XCTFail("Required bridge control could not be reached")
    }
    private func dismissReview(_ app: XCUIApplication) {
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap() }
    }
    private func waitForValue(_ value: String, on element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
