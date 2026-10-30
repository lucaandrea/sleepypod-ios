import XCTest

@MainActor final class PersonalRoutineUITests: XCTestCase {
    private func launch(_ mode: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--personal-routine-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20)); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        func visible() -> Bool {
            element.isHittable && element.frame.midY >= app.frame.minY + 110 && element.frame.midY <= app.frame.maxY - 40
        }
        for _ in 0..<20 where !visible() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: upward ? 0.78 : 0.28))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: upward ? 0.28 : 0.78))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        if !visible() { capture(app, "Unreachable-\(element.identifier)") }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func openReview(_ app: XCUIApplication) {
        let link = app.buttons["publication.accountLink"]; reveal(link, in: app); link.tap()
        XCTAssertTrue(app.navigationBars["Operating week"].waitForExistence(timeout: 10))
        reveal(app.staticTexts["publication.reason"], in: app)
    }
    private func confirm(_ app: XCUIApplication) {
        let first = app.switches["publication.confirmWeek"], second = app.switches["publication.confirmEffect"]
        reveal(first, in: app); first.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(first.value as? String, "1")
        reveal(second, in: app); second.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(second.value as? String, "1")
        let publish = app.buttons["publication.publish"]; reveal(publish, in: app); XCTAssertTrue(publish.isEnabled)
    }
    func testWholeWeekDetailsBothAcknowledgmentsAndSavedReceipt() {
        let app = launch("ready"); openReview(app)
        let sunday = app.buttons["publication.night.sunday"]
        reveal(sunday, in: app); sunday.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Monday 07:00")).firstMatch.exists)
        let snooze = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "9 min · 30%")).firstMatch
        reveal(snooze, in: app); capture(app, "Publication-full-alarm-fields")
        let publish = app.buttons["publication.publish"]; reveal(publish, in: app); XCTAssertFalse(publish.isEnabled)
        confirm(app); capture(app, "Publication-explicit-confirmations"); publish.tap()
        let result = app.staticTexts["publication.result"]; reveal(result, in: app, upward: false)
        XCTAssertEqual(result.label, "Operating week saved"); capture(app, "Publication-saved-receipt")
        app.terminate()
    }
    func testUnknownPublicationReadsReceiptWithoutRepublishing() {
        let app = launch("unknown"); openReview(app); confirm(app); app.buttons["publication.publish"].tap()
        let result = app.staticTexts["publication.result"]; reveal(result, in: app, upward: false)
        XCTAssertEqual(result.label, "Publication outcome unknown")
        let receipt = app.buttons["publication.receipt"]; reveal(receipt, in: app); receipt.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Scheduler refreshed")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "Publication-recovered-by-receipt"); app.terminate()
    }
    func testLargeTextUntouchedDraftCannotPublishAndFullReviewFits() {
        let app = launch("untouched", large: true); openReview(app)
        let routing = app.staticTexts["publication.routing"]; reveal(routing, in: app)
        XCTAssertEqual(routing.label, "Scheduled vibration · Left only")
        XCTAssertGreaterThanOrEqual(routing.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(routing.frame.maxX, app.frame.maxX)
        capture(app, "Publication-large-text-routing")
        let publish = app.buttons["publication.publish"]; reveal(publish, in: app); XCTAssertFalse(publish.isEnabled)
        capture(app, "Publication-large-text-disabled-confirmation"); app.terminate()
    }
    func testExplicitCopyAndClearStayDraftsUntilPublicationAndCancelReloadPreservesEdits() {
        let app = launch("untouched")
        let drafts = app.buttons["Weekly routine drafts"]; reveal(drafts, in: app); drafts.tap()
        let copy = app.buttons["publication.copyCurrent"]; reveal(copy, in: app); copy.tap()
        let copyConfirm = app.alerts.buttons["Copy current week"]; XCTAssertTrue(copyConfirm.waitForExistence(timeout: 10)); copyConfirm.tap()
        let save = app.buttons["household.routines.save"]; reveal(save, in: app); save.tap()
        let clear = app.buttons["publication.clearDraft"]; reveal(clear, in: app, upward: false); clear.tap(); app.alerts.buttons["Clear draft"].tap()
        let reload = app.buttons["publication.reloadDraft"]; reveal(reload, in: app, upward: false); reload.tap(); app.alerts.buttons["Cancel"].tap()
        let sunday = app.buttons["household.night.sunday"]; reveal(sunday, in: app, upward: false); sunday.tap()
        app.navigationBars.buttons.firstMatch.tap()
        reveal(save, in: app); save.tap()
        let review = app.buttons["publication.openReview"]; reveal(review, in: app); review.tap()
        XCTAssertTrue(app.staticTexts["publication.reason"].waitForExistence(timeout: 10))
        let removed = app.buttons["publication.night.sunday"]; reveal(removed, in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Sunday night · Remove")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["publication.result"].exists)
        capture(app, "Publication-clear-week-review-only"); app.terminate()
    }
}
