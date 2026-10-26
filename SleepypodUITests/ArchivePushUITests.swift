import XCTest
import UIKit

@MainActor final class ArchivePushUITests: XCTestCase {
    func testBackupConfigurationPublicKeyAndSavedConnectionTest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch()
        let route = app.buttons["settings.backup"]
        reveal(route, app: app); route.tap()
        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 5))
        capture(app, "Backup-destination")
        let enabled = app.switches["archive.enabled"]
        reveal(enabled, app: app); enabled.tap(); XCTAssertEqual(enabled.value as? String, "1")
        let remotePath = app.textFields["archive.path"]
        reveal(remotePath, app: app); replace(remotePath, identifier: "path", with: "/backups/owner", app: app)
        app.buttons["archive.keyboardDone"].tap()
        let save = app.buttons["archive.save"]
        reveal(save, app: app); XCTAssertTrue(save.isEnabled); save.tap()
        let receipt = app.staticTexts["archive.receipt"]
        reveal(receipt, app: app); XCTAssertTrue(receipt.label.contains("configuration saved"))
        capture(app, "Backup-saved")
        let key = app.buttons["archive.generateKey"]
        reveal(key, app: app); key.tap()
        let publicKey = app.staticTexts["archive.publicKey"]
        reveal(publicKey, app: app); XCTAssertTrue(publicKey.label.contains("not a usable SSH key"))
        capture(app, "Backup-public-key")
        let test = app.buttons["archive.test"]
        reveal(test, app: app); test.tap()
        let result = app.staticTexts["archive.testResult"]
        reveal(result, app: app); XCTAssertTrue(result.label.contains("No archive was transferred"))
        capture(app, "Backup-connection-test")
        let port = app.textFields["archive.port"]
        reveal(port, app: app); replace(port, identifier: "port", with: "70000", app: app)
        app.buttons["archive.keyboardDone"].tap()
        reveal(save, app: app); XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(app.staticTexts["Enter a port from 1 to 65535."].exists)
        capture(app, "Backup-validation")
    }
    private func replace(_ field: XCUIElement, identifier: String, with text: String, app: XCUIApplication) {
        field.tap()
        let clear = app.buttons["archive.clear.\(identifier)"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3)); clear.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<40 {
            let scroll = app.scrollViews["archive.content"]
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
        XCTFail("Backup control could not be reached")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
