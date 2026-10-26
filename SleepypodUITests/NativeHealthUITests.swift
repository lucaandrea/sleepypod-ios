import XCTest
import UIKit

@MainActor final class NativeHealthUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "health", "-userDefaultSide", "left",
            "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch()
        let navigation = app.navigationBars["Apple Health"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 15))
        // Native settings initially use a medium sheet; expand it before checking full-page captures.
        if navigation.frame.minY >= app.frame.height * 0.25 {
            navigation.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.12)))
        }
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            navigation.frame.minY < app.frame.height * 0.25
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 10), .completed)
        return app
    }
    func testSeparatePresenceAndStageConsentPersists() {
        let app = launch(), presence = app.switches["health.presence"], stages = app.switches["health.stages"]
        reveal(presence, app); let beforePresence = presence.value as? String
        presence.tap(); let savedPresence = presence.value as? String
        XCTAssertNotEqual(savedPresence, beforePresence); capture(app, "Health-presence")
        reveal(stages, app); let beforeStages = stages.value as? String
        stages.tap(); let savedStages = stages.value as? String
        XCTAssertNotEqual(savedStages, beforeStages); capture(app, "Health-estimates")
        app.terminate()
        let reopened = launch(); reveal(reopened.switches["health.presence"], reopened)
        XCTAssertEqual(reopened.switches["health.presence"].value as? String, savedPresence)
        reveal(reopened.switches["health.stages"], reopened)
        XCTAssertEqual(reopened.switches["health.stages"].value as? String, savedStages)
    }
    func testLinkedSideAndDemoCannotWriteHealth() {
        let app = launch(), side = app.segmentedControls["health.side"]
        reveal(side, app); XCTAssertEqual(side.buttons.count, 2)
        side.buttons.element(boundBy: 1).tap(); XCTAssertTrue(side.buttons.element(boundBy: 1).isSelected)
        capture(app, "Health-linked-side")
        let authorize = app.buttons["health.authorize"]; reveal(authorize, app)
        XCTAssertFalse(authorize.isEnabled)
        let sync = app.buttons["health.syncRecent"]; reveal(sync, app); XCTAssertFalse(sync.isEnabled); capture(app, "Health-demo-sync")
        let rebuild = app.buttons["health.rebuild"]; reveal(rebuild, app); XCTAssertFalse(rebuild.isEnabled)
        let notice = app.staticTexts["Demo mode never writes to Apple Health. Connect a pod to sync."]
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(notice.exists)
        XCTAssertGreaterThanOrEqual(notice.frame.minY, app.scrollViews.firstMatch.frame.minY)
        XCTAssertLessThanOrEqual(notice.frame.maxY, app.scrollViews.firstMatch.frame.maxY)
        capture(app, "Health-demo-rebuild")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<30 {
            if element.exists && element.isHittable && element.frame.midY > 115 && element.frame.maxY < scroll.frame.maxY - 8 { return }
            let up = element.exists && element.frame.midY < 115
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.3 : 0.73)).press(forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.73 : 0.3)))
        }
        XCTFail("Control not reachable: \(element), frame \(element.frame), viewport \(scroll.frame)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
