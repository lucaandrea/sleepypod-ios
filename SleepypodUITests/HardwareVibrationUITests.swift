import XCTest
import UIKit

@MainActor final class HardwareVibrationUITests: XCTestCase {
    func testCustomDurationAndSelectedSidePlayStop() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        reveal(app.buttons["system.hardware"], app: app); app.buttons["system.hardware"].tap()
        XCTAssertTrue(app.navigationBars["Hardware"].waitForExistence(timeout: 8))
        XCTAssertLessThan(app.navigationBars["Hardware"].frame.minY, app.frame.height * 0.25, "Diagnostics should use the full screen")
        let side = app.buttons["vibration.side"]
        reveal(side, app: app); side.tap()
        choose("Right", app: app)
        XCTAssertEqual(app.buttons["vibration.play"].label, "Play on Right")
        let preset = app.buttons["vibration.preset"]
        reveal(preset, app: app); preset.tap()
        choose("Custom", app: app)
        let duration = app.steppers["vibration.duration"]
        reveal(duration, app: app); duration.buttons["vibration.duration-Increment"].tap()
        XCTAssertEqual(duration.value as? String, "11")
        capture(app, "Hardware-custom-duration")
        reveal(preset, app: app); preset.tap()
        choose("Long", app: app)
        let play = app.buttons["vibration.play"]
        reveal(play, app: app); XCTAssertEqual(play.label, "Play on Right"); play.tap()
        let notice = app.staticTexts["vibration.notice"]
        reveal(notice, app: app)
        XCTAssertTrue(notice.label.contains("accepted"))
        capture(app, "Hardware-requested-test")
        let stop = app.buttons["vibration.stop"]
        reveal(stop, app: app); XCTAssertTrue(stop.label.contains("Right")); stop.tap()
        reveal(notice, app: app)
        XCTAssertEqual(notice.label, "Stop accepted for the right side.")
        capture(app, "Hardware-stop-result")
    }
    private func choose(_ title: String, app: XCUIApplication) {
        let option = app.collectionViews.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<40 {
            let content = app.scrollViews["vibration.content"]
            let surface = content.exists ? content : app
            let visible = surface.frame.intersection(app.frame).insetBy(dx: 0, dy: 50)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = element.exists && element.frame.midY < visible.minY
            let distance = min(230, visible.height * 0.4)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY + (down ? distance : -distance)))
            if UIDevice.current.userInterfaceIdiom == .pad {
                if down { surface.swipeDown(velocity: .slow) } else { surface.swipeUp(velocity: .slow) }
            } else { start.press(forDuration: 0.05, thenDragTo: end) }
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
