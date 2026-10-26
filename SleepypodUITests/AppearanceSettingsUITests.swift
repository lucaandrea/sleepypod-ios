import XCTest
import UIKit

@MainActor final class AppearanceSettingsUITests: XCTestCase {
    func testAllSettingsUnitActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 12))
        for title in ["Celsius (°C)", "Fahrenheit (°F)", "Celsius (°C)"] { choose("settings.units", title, app) }
    }
    func testPreferencesUnitsAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings"]
        app.launch(); openAppearance(app)
        choose("appearance.layout", "Stage", app)
        for title in ["Night & Dawn", "Both sides", "Dial", "Slider"] { choose("appearance.control", title, app) }
        for title in ["Degrees", "Offset", "Eight Sleep"] { choose("temperature.display", title, app) }
        choose("appearance.units", "°C", app)
        capture(app, "Appearance-temperature")
        for title in ["Off", "On selection", "Always"] { choose("temperature.zones", title, app) }
        let autoReturn = app.switches["appearance.autoReturn"]; reveal(autoReturn, app)
        if autoReturn.value as? String == "1" { autoReturn.tap() }
        XCTAssertEqual(autoReturn.value as? String, "0"); capture(app, "Appearance-stage")
        for title in ["System", "Dark", "Light"] {
            choose("appearance.theme", title, app)
            if title != "System" { assertRenderedTheme(title, app) }
        }
        capture(app, "Appearance-light")
        app.terminate(); app.launch(); openAppearance(app)
        assertValue("appearance.layout", "Stage", app)
        assertValue("appearance.control", "Slider", app)
        assertValue("temperature.display", "Eight Sleep", app)
        assertValue("temperature.zones", "Always", app)
        reveal(autoReturn, app); XCTAssertEqual(autoReturn.value as? String, "0")
        assertValue("appearance.theme", "Light", app)
        choose("appearance.theme", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark", app)
        assertRenderedTheme(UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark", app)
        capture(app, "Appearance-restored")
    }
    private func openAppearance(_ app: XCUIApplication) {
        let link = app.buttons["settings.allAppearance"]; XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 12))
        reveal(link, app); link.tap(); XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    }
    private func choose(_ identifier: String, _ title: String, _ app: XCUIApplication) {
        let menu = app.buttons[identifier]; reveal(menu, app); menu.tap()
        // The Temp tab can retain identically named controls behind this settings cover.
        let option = app.buttons["\(identifier).option.\(title)"]
        XCTAssertTrue(option.waitForExistence(timeout: 3), app.debugDescription)
        option.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            menu.exists && (menu.label.contains(title) || menu.value as? String == title)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 6), .completed, app.debugDescription)
        assertValue(identifier, title, app)
    }
    private func assertValue(_ identifier: String, _ title: String, _ app: XCUIApplication) {
        let menu = app.buttons[identifier]; reveal(menu, app)
        XCTAssertTrue(menu.label.contains(title) || menu.value as? String == title, "\(identifier): \(menu.label) / \(String(describing: menu.value))")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<65 {
            let appearance = app.scrollViews["appearance.content"]
            let surface = appearance.exists && appearance.isHittable ? appearance : app
            let bounds = surface.frame.intersection(app.frame), nav = app.navigationBars.firstMatch
            let top = nav.exists ? max(bounds.minY, nav.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 10))
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = !(element.exists && element.frame.midY < visible.minY)
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.75 : 0.35)).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: down ? 0.35 : 0.75)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func assertRenderedTheme(_ title: String, _ app: XCUIApplication) {
        // Inspect the padded scroll background, so changing a label alone cannot pass the theme check.
        let frame = app.scrollViews["appearance.content"].frame
        guard let image = app.screenshot().image.cgImage else { return XCTFail("Missing screenshot") }
        let scale = CGFloat(image.width) / app.frame.width
        let point = CGRect(x: (frame.minX + 4) * scale, y: (frame.minY + 4) * scale, width: 1, height: 1)
        guard let pixel = image.cropping(to: point) else { return XCTFail("Missing background pixel") }
        var channels = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &channels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let brightness = channels.prefix(3).map(Double.init).reduce(0, +) / 3
        XCTAssertTrue(title == "Dark" ? brightness < 80 : brightness > 180, "\(title) background brightness: \(brightness)")
    }
}
