import XCTest
import UIKit

@MainActor final class BedCareUITests: XCTestCase {
    func testCareLinksAndRecoveryWithoutAutomaticRepair() { verify(large: false) }
    func testCareAtMaximumTextSize() { verify(large: true) }
    private func verify(large: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-uiRoute", "settings", "-household.personalWorkspaceActive", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app); capture(large ? "Care-large-entry" : "Care-entry"); status.tap()
        let care = app.buttons["system.care"]; reveal(care, app); care.tap()
        XCTAssertTrue(app.navigationBars["Bed care"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Practice · simulated care checks"].waitForExistence(timeout: 10))
        let water = app.staticTexts["care.water"]; reveal(water, app)
        XCTAssertTrue(app.staticTexts["The Pod reports low water."].exists)
        capture(large ? "Care-large-text" : "Care-current-checks")
        let backup = app.staticTexts["care.backup"]; reveal(backup, app)
        XCTAssertTrue(app.buttons["care.open.backup"].exists)
        let recovery = app.buttons["care.recovery"]; reveal(recovery, app); recovery.tap()
        let instructions = app.descendants(matching: .any).matching(identifier: "care.instructions").firstMatch
        reveal(instructions, app)
        capture("Care-recovery")
        XCTAssertFalse(app.buttons["Restart"].exists)
        XCTAssertFalse(app.buttons["Start priming"].exists)
        if !large {
            let protection = app.buttons["care.open.protectionSettings"]
            reveal(protection, app); capture("Care-protection-link"); protection.tap()
            XCTAssertTrue(app.navigationBars["Pump protection"].waitForExistence(timeout: 5))
            app.navigationBars["Pump protection"].buttons.firstMatch.tap()
            let storage = app.buttons["care.open.storage"]; reveal(storage, app); storage.tap()
            XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 5))
        }
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<24 {
            // iPad settings are a centered sheet: screen bounds do not describe its visible content.
            let container = scrollContainer(for: element, in: app)
            let navigationBottom = app.navigationBars.allElementsBoundByIndex
                .filter { $0.frame.intersects(container.frame) && $0.isHittable }.map(\.frame.maxY).max() ?? app.frame.minY
            let contentTop = max(app.frame.minY + 120, navigationBottom + 12)
            let screenContent = CGRect(x: app.frame.minX, y: contentTop,
                                       width: app.frame.width, height: app.frame.maxY - 40 - contentTop)
            let viewport = container.frame.insetBy(dx: 0, dy: 24).intersection(screenContent)
            if element.exists, element.frame.height > 0 {
                // Large-text disclosure labels can extend beyond the viewport even with a clear tap point.
                let visible = viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
                if visible, element.isHittable { return }
            }
            let upward = !element.exists || element.frame.midY >= viewport.minY
            if upward { container.swipeUp() } else { container.swipeDown() }
        }
        capture("Care-unreachable"); print(app.debugDescription)
        XCTFail("Could not reach care control: \(element)")
    }
    private func scrollContainer(for element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        guard element.exists else { return app }
        let predicate = element.identifier.isEmpty
            ? NSPredicate(format: "label == %@", element.label)
            : NSPredicate(format: "identifier == %@", element.identifier)
        return app.scrollViews.containing(predicate).allElementsBoundByIndex
            .filter { $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.intersects(app.frame) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
