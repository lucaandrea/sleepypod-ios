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
        reveal(status, app); status.tap()
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
            let protection = app.buttons["care.open.protectionSettings"]; reveal(protection, app); protection.tap()
            XCTAssertTrue(app.navigationBars["Pump protection"].waitForExistence(timeout: 5))
            app.navigationBars["Pump protection"].buttons.firstMatch.tap()
            let storage = app.buttons["care.open.storage"]; reveal(storage, app); storage.tap()
            XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 5))
        }
        app.terminate()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<24 {
            if element.exists, element.isHittable, element.frame.midY > 110, element.frame.midY < app.frame.maxY - 60 { return }
            if element.exists, element.frame.midY < 110 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTFail("Could not reach \(element.identifier)")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
