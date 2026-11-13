import XCTest
import UIKit

@MainActor final class LaterWakeUITests: XCTestCase {
    private func launch(_ scenario: String = "later-normal", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-uiRoute", "allsettings", "-uiNextAlarmScenario", scenario, "-userDefaultSide", "left", "-temperatureFormat", "fahrenheit",
            "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL",
            "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let link = app.buttons["Next alarm"]; reveal(link, app); link.tap()
        XCTAssertTrue(app.navigationBars["Next alarm"].waitForExistence(timeout: 5))
        let begin = app.buttons["laterWake.begin"].firstMatch; reveal(begin, app); XCTAssertTrue(begin.isEnabled); begin.tap()
        return app
    }
    func testPreviewSaveAndRestoreOneOccurrence() {
        let app = launch()
        capture(app, "Later-draft")
        preview(app)
        let warming = app.staticTexts["laterWake.warming"].firstMatch
        reveal(warming, app); XCTAssertTrue(warming.label.contains("7:30")); XCTAssertTrue(warming.label.contains("105")); capture(app, "Later-preview-times")
        let save = app.buttons["laterWake.save"].firstMatch; reveal(save, app); capture(app, "Later-preview-save"); XCTAssertTrue(save.isEnabled); save.tap()
        let result = app.otherElements["laterWake.result"].firstMatch
        reveal(app.staticTexts["Later wake saved on the Pod"].firstMatch, app)
        capture(app, "Later-saved")
        XCTAssertFalse(app.buttons["laterWake.save"].exists)
        let restore = app.buttons["nextAlarm.restore"].firstMatch; reveal(restore, app); restore.tap()
        let notice = app.staticTexts["nextAlarm.notice"].firstMatch; reveal(notice, app)
        XCTAssertTrue(notice.label.contains("One-time change saved"))
        let restoredWake = app.staticTexts["7:00 AM"].firstMatch
        reveal(restoredWake, app); capture(app, "Later-restored")
        _ = result
    }
    func testInvalidTimeAndExpiredPreviewKeepSaveUnavailable() {
        let app = launch("later-expired")
        let button = app.buttons["laterWake.preview"].firstMatch; reveal(button, app); button.tap()
        let error = app.descendants(matching: .any).matching(identifier: "laterWake.error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5)); XCTAssertTrue(error.isHittable)
        XCTAssertTrue(error.label.contains("later time")); capture(app, "Later-invalid-time")
        preview(app)
        let expired = app.descendants(matching: .any).matching(identifier: "laterWake.expired").firstMatch
        XCTAssertTrue(expired.waitForExistence(timeout: 12)); reveal(expired, app); capture(app, "Later-expired")
        XCTAssertFalse(app.buttons["laterWake.save"].firstMatch.isEnabled)
    }
    func testLostReplyRequiresReadbackWithoutReplay() {
        let app = launch("later-lost"); preview(app)
        let save = app.buttons["laterWake.save"].firstMatch; reveal(save, app); save.tap()
        let error = app.descendants(matching: .any).matching(identifier: "laterWake.error").firstMatch; reveal(error, app)
        XCTAssertTrue(error.label.contains("may already have been saved")); capture(app, "Later-unknown")
        let refresh = app.buttons["nextAlarm.reload"].firstMatch; reveal(refresh, app); refresh.tap()
        let changed = app.descendants(matching: .any).matching(identifier: "laterWake.changed").firstMatch
        reveal(changed, app); capture(app, "Later-readback-changed")
        XCTAssertFalse(app.buttons["laterWake.preview"].firstMatch.isEnabled)
        XCTAssertFalse(error.exists)
    }
    func testOptionalPhoneResultAndFailureRemainSeparate() {
        for scenario in ["later-normal", "later-phone-failure"] {
            let app = launch(scenario), toggle = app.switches["laterWake.phone"].firstMatch
            reveal(toggle, app); toggle.tap(); preview(app)
            let phoneTime = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Phone backup:")).firstMatch
            reveal(phoneTime, app); capture(app, "Later-phone-review-\(scenario)")
            let save = app.buttons["laterWake.save"].firstMatch; reveal(save, app); capture(app, "Later-phone-save-\(scenario)"); save.tap()
            let title = app.staticTexts[scenario == "later-normal" ? "Phone backup scheduled" : "Phone backup not confirmed"].firstMatch
            reveal(title, app); capture(app, "Later-phone-result-\(scenario)")
            XCTAssertTrue(app.staticTexts["Later wake saved on the Pod"].firstMatch.exists)
            app.terminate()
        }
    }
    func testUnavailableAndConcurrentPlansRemainDistinct() {
        for scenario in ["later-changed", "later-offline"] {
            let app = launch(scenario); preview(app)
            let reload = app.buttons["nextAlarm.reload"].firstMatch; reveal(reload, app); reload.tap()
            let identifier = scenario == "later-changed" ? "laterWake.changed" : "laterWake.unavailable"
            let message = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            reveal(message, app); capture(app, scenario)
            XCTAssertFalse(app.buttons["laterWake.save"].firstMatch.isEnabled)
            app.terminate()
        }
    }
    func testLargeTextKeepsTimeReviewAndActionReachable() {
        let app = launch(large: true)
        let picker = app.datePickers["laterWake.time"].firstMatch; reveal(picker, app); capture(app, "Later-large-draft")
        preview(app)
        let warming = app.staticTexts["laterWake.warming"].firstMatch; reveal(warming, app); capture(app, "Later-large-times")
        let save = app.buttons["laterWake.save"].firstMatch; reveal(save, app); XCTAssertTrue(save.isEnabled); capture(app, "Later-large-action")
    }
    func testPreviewFailureIsVisibleAtActionWithLargeText() {
        for scenario in ["later-normal", "later-preview-rejected"] {
            let app = launch(scenario, large: true)
            if scenario == "later-preview-rejected" {
                let choice = app.buttons["laterWake.add60"].firstMatch; reveal(choice, app); choice.tap()
            }
            let action = app.buttons["laterWake.preview"].firstMatch; reveal(action, app); action.tap()
            let error = app.descendants(matching: .any).matching(identifier: "laterWake.error").firstMatch
            XCTAssertTrue(error.waitForExistence(timeout: 5)); XCTAssertTrue(error.isHittable)
            capture(app, "Later-large-error-\(scenario)")
            XCTAssertFalse(app.buttons["laterWake.save"].exists)
            app.terminate()
        }
    }
    func testRestoreBoundarySurvivesReopeningAndBackground() {
        let app = saveWithPhone()
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.navigationBars["Next alarm"].waitForExistence(timeout: 10))
        let boundary = app.staticTexts["laterWake.restoreBoundary"].firstMatch
        reveal(boundary, app); capture(app, "Later-restore-after-background")
        app.navigationBars["Next alarm"].buttons["Settings"].tap()
        let link = app.buttons["Next alarm"]; reveal(link, app); link.tap()
        XCTAssertTrue(app.navigationBars["Next alarm"].waitForExistence(timeout: 5))
        reveal(boundary, app); capture(app, "Later-restore-after-reopen")
        let begin = app.buttons["laterWake.begin"].firstMatch; reveal(begin, app); begin.tap()
        let close = app.buttons["laterWake.close"].firstMatch; reveal(close, app); close.tap()
        reveal(boundary, app); capture(app, "Later-restore-after-review")
        let restore = app.buttons["nextAlarm.restore"].firstMatch; reveal(restore, app); restore.tap()
        let notice = app.staticTexts["nextAlarm.notice"].firstMatch; reveal(notice, app)
        XCTAssertTrue(notice.label.contains("phone backup is unchanged"))
        let details = app.buttons["wake.backup.details"].firstMatch; reveal(details, app); details.tap()
        let mismatch = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This backup differs")).firstMatch
        reveal(mismatch, app); capture(app, "Later-restored-phone-differs")
    }
    func testPhoneRemovalAndMissingCheckWithdrawConfirmation() {
        for scenario in ["later-normal", "later-phone-missing"] {
            let app = saveWithPhone(scenario)
            let details = app.buttons["wake.backup.details"].firstMatch; reveal(details, app); details.tap()
            if scenario == "later-normal" {
                let remove = app.buttons["wake.backup.remove"].firstMatch; reveal(remove, app); remove.tap()
            } else {
                let check = app.buttons["wake.backup.check"].firstMatch; reveal(check, app); check.tap()
            }
            reveal(details, app); details.tap()
            let title = app.staticTexts["Phone backup not confirmed"].firstMatch; reveal(title, app)
            XCTAssertFalse(app.staticTexts["Phone backup scheduled"].exists)
            XCTAssertTrue(app.staticTexts["Later wake saved on the Pod"].exists)
            capture(app, "Later-current-phone-\(scenario)")
            app.terminate()
        }
    }
    private func saveWithPhone(_ scenario: String = "later-normal") -> XCUIApplication {
        let app = launch(scenario), toggle = app.switches["laterWake.phone"].firstMatch
        reveal(toggle, app); toggle.tap(); preview(app)
        let save = app.buttons["laterWake.save"].firstMatch; reveal(save, app); save.tap()
        let title = app.staticTexts["Phone backup scheduled"].firstMatch; reveal(title, app)
        return app
    }
    private func preview(_ app: XCUIApplication) {
        let choice = app.buttons["laterWake.add60"].firstMatch; reveal(choice, app); choice.tap()
        let preview = app.buttons["laterWake.preview"].firstMatch; reveal(preview, app); preview.tap()
        XCTAssertTrue(app.buttons["laterWake.save"].firstMatch.waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<40 {
            let bounds = app.frame.insetBy(dx: 0, dy: app.frame.width > 600 ? 100 : 120)
            let frame = element.exists ? element.frame : .zero
            if element.exists, element.isHittable, bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            let upward = frame.isEmpty || frame.midY > bounds.midY
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: upward ? 0.70 : 0.30)).press(forDuration: 0.05,
                thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: upward ? 0.30 : 0.70)))
        }
        XCTFail("Cannot reach later-wake control: \(element)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
