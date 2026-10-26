import XCTest
import UIKit

@MainActor final class SleeperGestureUITests: XCTestCase {
    func testBedSetupAwayAndPresenceControls() {
        let app = launch()
        let route = app.buttons["settings.sides"]; reveal(route, app: app); route.tap()
        XCTAssertTrue(app.navigationBars["Sides"].waitForExistence(timeout: 5))
        capture(app, "Sides-bed")
        let mode = app.buttons["sleepers.bedMode"]; reveal(mode, app: app); mode.tap(); app.buttons["Solo · right"].tap()
        let other = app.buttons["sleepers.otherZone"]; reveal(other, app: app); other.tap(); app.buttons["Follow my schedule"].tap()
        let saveBed = app.buttons["sleepers.saveBed"]; reveal(saveBed, app: app); saveBed.tap()
        let receipt = app.staticTexts["sleepers.receipt"]; reveal(receipt, app: app); XCTAssertEqual(receipt.label, "Settings saved.")
        capture(app, "Sides-setup-saved")
        let left = app.buttons["sleepers.left"]; reveal(left, app: app); left.tap()
        let away = app.switches["sleepers.away"]; reveal(away, app: app); away.tap(); XCTAssertEqual(away.value as? String, "1")
        XCTAssertFalse(receipt.exists, "An earlier section's receipt must not label unsaved profile changes as saved")
        let hasReturn = app.switches["sleepers.hasReturn"]; reveal(hasReturn, app: app); hasReturn.tap()
        XCTAssertTrue(app.datePickers["sleepers.returnDate"].exists)
        capture(app, "Sides-away")
        let always = app.switches["sleepers.alwaysOn"]; reveal(always, app: app); always.tap(); XCTAssertEqual(always.value as? String, "1")
        let autoOff = app.switches["sleepers.autoOff"]; reveal(autoOff, app: app); XCTAssertTrue(autoOff.isEnabled); autoOff.tap()
        reveal(always, app: app); XCTAssertEqual(always.value as? String, "0")
        capture(app, "Sides-presence")
        let autoOn = app.switches["sleepers.autoOn"]; reveal(autoOn, app: app); XCTAssertTrue(autoOn.isEnabled); autoOn.tap(); XCTAssertEqual(autoOn.value as? String, "1")
        let dwell = app.steppers["sleepers.onMinutes"]; reveal(dwell, app: app); dwell.buttons["sleepers.onMinutes-Increment"].tap()
        XCTAssertTrue(app.datePickers["sleepers.windowStart"].exists)
        capture(app, "Sides-auto-on")
        let save = app.buttons["sleepers.saveSide"]; reveal(save, app: app); save.tap()
        reveal(receipt, app: app); XCTAssertEqual(receipt.label, "Settings saved.")
        capture(app, "Sides-saved")
        reveal(away, app: app); XCTAssertEqual(away.value as? String, "1")
        reveal(autoOff, app: app); XCTAssertEqual(autoOff.value as? String, "1")
    }
    func testGestureCreateEditAndRemove() {
        let app = launch()
        let route = app.buttons["settings.gestures"]; reveal(route, app: app); route.tap()
        XCTAssertTrue(app.navigationBars["Tap gestures"].waitForExistence(timeout: 5))
        let mapping = app.buttons["gestures.doubleTap"]; reveal(mapping, app: app)
        XCTAssertTrue(mapping.label.contains("Not set")); capture(app, "Gestures-empty"); mapping.tap()
        let direction = app.buttons["gestures.direction"]; reveal(direction, app: app); direction.tap(); app.buttons["Cooler"].tap()
        let amount = app.steppers["gestures.amount"]; reveal(amount, app: app); amount.buttons["gestures.amount-Increment"].tap()
        capture(app, "Gestures-temperature")
        let save = app.buttons["gestures.save"]; reveal(save, app: app); save.tap()
        XCTAssertTrue(mapping.waitForExistence(timeout: 5)); reveal(mapping, app: app)
        XCTAssertTrue(mapping.label.contains("−3°F")); capture(app, "Gestures-saved"); mapping.tap()
        let action = app.buttons["gestures.action"]; reveal(action, app: app); action.tap(); app.buttons["Alarm / power"].tap()
        let idle = app.buttons["gestures.idle"]; reveal(idle, app: app); idle.tap(); app.buttons["Power on / off"].tap()
        let ringing = app.buttons["gestures.ringing"]; reveal(ringing, app: app); ringing.tap(); app.buttons["Stop alarm"].tap()
        capture(app, "Gestures-alarm")
        reveal(save, app: app); save.tap()
        XCTAssertTrue(mapping.waitForExistence(timeout: 5)); reveal(mapping, app: app)
        XCTAssertTrue(mapping.label.contains("Power on / off")); XCTAssertTrue(mapping.label.contains("Stop alarm")); mapping.tap()
        let remove = app.buttons["gestures.remove"]; reveal(remove, app: app); remove.tap()
        app.buttons["Remove"].tap()
        XCTAssertTrue(mapping.waitForExistence(timeout: 5)); reveal(mapping, app: app); XCTAssertTrue(mapping.label.contains("Not set"))
        capture(app, "Gestures-removed")
    }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings", "-userDefaultSide", "left"]
        app.launch(); return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<55 {
            let surface = ["gestures.editor", "sleepers.content", "gestures.content"].map { app.scrollViews[$0] }.first { $0.exists && $0.isHittable } ?? app
            let bounds = surface.frame.intersection(app.frame)
            let navigation = app.navigationBars.firstMatch
            let top = navigation.exists ? max(bounds.minY, navigation.frame.maxY + 8) : bounds.minY
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 10))
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let upward = !(element.exists && element.frame.midY < visible.minY)
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upward ? 0.70 : 0.35))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upward ? 0.35 : 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Setting could not be reached: \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
