import XCTest
import UIKit

@MainActor final class SystemStorageUITests: XCTestCase {
    func testReviewCancelAndExplicitDemoCleanup() {
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        reveal(app.buttons["system.storage"], app: app); app.buttons["system.storage"].tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 8))
        XCTAssertLessThan(app.navigationBars["Storage"].frame.minY, app.frame.height * 0.25, "Diagnostics should use the full screen")
        capture(app, "Storage-usage")
        let backups = app.switches["storage.backups"]
        reveal(backups, app: app)
        XCTAssertEqual(backups.value as? String, "0")
        capture(app, "Storage-candidates")
        let review = app.buttons["storage.review"]
        reveal(review, app: app); review.tap()
        XCTAssertTrue(app.alerts["Delete eligible leftovers?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["storage.result"].exists)
        reveal(backups, app: app); backups.tap()
        XCTAssertEqual(backups.value as? String, "1")
        reveal(review, app: app); review.tap()
        let confirmation = app.alerts["Delete eligible leftovers?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Old database backups are included")).firstMatch.exists)
        capture(app, "Storage-confirmation")
        confirmation.buttons["Delete"].tap()
        let result = app.staticTexts["storage.result"]
        reveal(result, app: app)
        XCTAssertTrue(result.label.contains("3 items"))
        XCTAssertTrue(app.staticTexts["storage.empty"].exists)
        capture(app, "Storage-result")
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<40 {
            let content = app.scrollViews["storage.content"]
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
