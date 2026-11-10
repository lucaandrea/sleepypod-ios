import XCTest

@MainActor final class OfflineLibraryUITests: XCTestCase {
    private func launch(_ page: String, large: Bool = false, savedOnly: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--offline-library-fixture", "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO",
                               "-uiOfflinePage", page, "-uiOfflineReadOnly", savedOnly ? "YES" : "NO",
                               "-household.personalWorkspaceActive", "NO", "-appearance", "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["Viewing saved data"].waitForExistence(timeout: 30))
        return app
    }

    func testDisconnectedSleepKeepsRecordsAndLocalReportsAccessible() {
        let app = launch("sleep")
        XCTAssertTrue(app.staticTexts["Recent bed recordings"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["offline.lastSynced"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Offline-sleep"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(app.buttons["Edit sleep times"].exists)
        app.buttons["offline.reports"].tap()
        XCTAssertTrue(app.navigationBars["Saved reports"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create my report"].exists)
        app.terminate()
    }

    func testOfflineScheduleIsReadOnlyAndSwitchesSide() {
        let app = launch("schedule")
        XCTAssertTrue(app.staticTexts["Confirmed weekly plan"].waitForExistence(timeout: 15))
        app.segmentedControls.buttons["Right"].tap()
        XCTAssertTrue(app.staticTexts["offline.lastSynced"].exists)
        XCTAssertEqual(app.switches.count, 0)
        XCTAssertFalse(app.buttons["Save"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Offline-schedule"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
    }

    func testLargeTextLeavesConnectionAndRecordsReachable() {
        let app = launch("sleep", large: true)
        let saved = app.staticTexts["Recent bed recordings"]
        for _ in 0..<8 where !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.isHittable)
        XCTAssertGreaterThanOrEqual(saved.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(saved.frame.maxX, app.frame.maxX)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Offline-large-text"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
    }

    /// Run UI tests with simulator signing enabled: Keychain deliberately rejects
    /// unsigned runners. The second launch cannot fetch even synthetic records.
    func testEncryptedLibraryReopensAfterTerminationWithoutFetching() {
        var app = launch("sleep")
        XCTAssertTrue(app.staticTexts["Recent bed recordings"].waitForExistence(timeout: 15))
        app.terminate()
        app = launch("sleep", savedOnly: true)
        XCTAssertTrue(app.staticTexts["Recent bed recordings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["offline.lastSynced"].exists)
        app.terminate()
        app = launch("schedule", savedOnly: true)
        XCTAssertTrue(app.staticTexts["Confirmed weekly plan"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
