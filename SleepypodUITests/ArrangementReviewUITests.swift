import XCTest

@MainActor final class ArrangementReviewUITests: XCTestCase {
    private func launch(_ mode: String, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--arrangement-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20)); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 40 }
        var towardBottom = upward
        for _ in 0..<32 {
            if visible() { break }
            if element.exists {
                if element.frame.midY >= app.frame.maxY - 40 { towardBottom = true }
                else if element.frame.midY <= app.frame.minY + 110 { towardBottom = false }
            } else if !towardBottom && app.staticTexts["Review your future sides together."].exists && app.staticTexts["Review your future sides together."].isHittable {
                // Inserting a review can move a large-text Form back to its beginning.
                towardBottom = true
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: towardBottom ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: towardBottom ? 0.28 : 0.78)))
        }
        guard visible() else { capture(app, "Unreachable-\(element.identifier)"); XCTFail("Unreachable \(element.identifier)"); return }
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func open(_ app: XCUIApplication) {
        let link = app.buttons["arrangement.accountLink"]; reveal(link, in: app); link.tap()
        XCTAssertTrue(app.navigationBars["Shared side review"].waitForExistence(timeout: 10))
    }
    private func confirm(_ app: XCUIApplication) {
        for identifier in ["arrangement.confirmSide", "arrangement.confirmRoutine", "arrangement.confirmActivation"] {
            let toggle = app.switches[identifier]; reveal(toggle, in: app)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
        }
        let approve = app.buttons["arrangement.approve"]; reveal(approve, in: app); XCTAssertTrue(approve.isEnabled)
    }
    func testOwnerReviewsActualWeekConfirmsAndCanCancelWithoutActivation() {
        let app = launch("owner"); open(app)
        let source = app.staticTexts["arrangement.source"]; reveal(source, in: app)
        XCTAssertTrue(source.label.contains("current operating week"))
        let sunday = app.buttons["arrangement.night.sunday"]; reveal(sunday, in: app); sunday.tap()
        let snooze = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "9 min · 30%")).firstMatch
        reveal(snooze, in: app); capture(app, "Arrangement-preserved-owner-alarm")
        let approve = app.buttons["arrangement.approve"]; reveal(approve, in: app); XCTAssertFalse(approve.isEnabled)
        reveal(app.switches["arrangement.confirmSide"], in: app, upward: false); confirm(app)
        capture(app, "Arrangement-three-independent-confirmations"); approve.tap()
        let notice = app.staticTexts["arrangement.notice"]; reveal(notice, in: app, upward: false)
        XCTAssertTrue(notice.label.contains("Your approval is saved"))
        let cancel = app.buttons["arrangement.cancel"]; reveal(cancel, in: app); cancel.tap()
        let confirmCancel = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Cancel side review", "arrangement.cancel")).firstMatch
        XCTAssertTrue(confirmCancel.waitForExistence(timeout: 5)); confirmCancel.tap()
        let status = app.staticTexts["arrangement.status"]; reveal(status, in: app, upward: false)
        XCTAssertTrue(status.label.contains("cancelled")); capture(app, "Arrangement-cancelled-bed-unchanged")
        app.terminate()
    }
    func testMemberPrivateEmptyWeekAndLargeTextConfirmationsFit() {
        let app = launch("member", large: true); open(app)
        let status = app.staticTexts["arrangement.status"]; reveal(status, in: app); capture(app, "Arrangement-member-large-text-sides")
        let source = app.staticTexts["arrangement.source"]; reveal(source, in: app); XCTAssertTrue(source.label.contains("saved private draft"))
        let sunday = app.buttons["arrangement.night.sunday"]; reveal(sunday, in: app); sunday.tap()
        let empty = app.staticTexts["No routine for this bedtime night."]; reveal(empty, in: app)
        XCTAssertFalse(app.staticTexts["Notes · Synthetic example only"].exists)
        confirm(app); capture(app, "Arrangement-member-large-text-approval")
        app.buttons["arrangement.approve"].tap()
        let notice = app.staticTexts["arrangement.notice"]; reveal(notice, in: app, upward: false)
        XCTAssertTrue(notice.label.contains("Your approval is saved")); app.terminate()
    }
    func testLostReplyRequiresCurrentReviewCheck() {
        let app = launch("unknown"); open(app); confirm(app); app.buttons["arrangement.approve"].tap()
        let error = app.staticTexts["arrangement.error"]; reveal(error, in: app, upward: false)
        XCTAssertTrue(error.label.contains("will not be resent")); capture(app, "Arrangement-unknown-response")
        let refresh = app.buttons["arrangement.refresh"]; reveal(refresh, in: app, upward: false); refresh.tap()
        let notice = app.staticTexts["arrangement.notice"]; reveal(notice, in: app)
        XCTAssertTrue(notice.label.contains("Current side review checked"))
        XCTAssertFalse(app.buttons["arrangement.approve"].exists); capture(app, "Arrangement-approval-reconciled"); app.terminate()
    }
    func testOwnerProposalLargeTextRequiresPreservingOperatingWeek() {
        let app = launch("propose", large: true); open(app)
        let left = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Left")).firstMatch
        reveal(left, in: app); left.tap(); capture(app, "Arrangement-scaled-side-picker")
        let propose = app.buttons["arrangement.propose"]; reveal(propose, in: app); XCTAssertFalse(propose.isEnabled)
        let preserve = app.switches["arrangement.preserveWeek"]; reveal(preserve, in: app, upward: false)
        preserve.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); XCTAssertEqual(preserve.value as? String, "1")
        reveal(propose, in: app); XCTAssertTrue(propose.isEnabled); capture(app, "Arrangement-owner-large-text-proposal"); propose.tap()
        let notice = app.staticTexts["arrangement.notice"]; reveal(notice, in: app, upward: false)
        XCTAssertTrue(notice.label.contains("Review prepared"))
        let ownSide = app.descendants(matching: .any).matching(identifier: "arrangement.side.left").firstMatch
        reveal(ownSide, in: app); XCTAssertTrue(ownSide.label.contains("Your proposed side")); capture(app, "Arrangement-owner-left-side-selected")
        app.terminate()
    }
    func testExpiredReviewAndUnavailableCapabilityAreHonest() {
        var app = launch("expired"); open(app)
        let status = app.staticTexts["arrangement.status"]; reveal(status, in: app); XCTAssertTrue(status.label.contains("expired"))
        let approve = app.buttons["arrangement.approve"]; reveal(approve, in: app); XCTAssertFalse(approve.isEnabled)
        capture(app, "Arrangement-expired-review"); app.terminate()
        app = launch("disabled")
        let link = app.buttons["arrangement.accountLink"]; reveal(link, in: app); XCTAssertFalse(link.isEnabled)
        let availability = app.staticTexts["arrangement.availability"]; reveal(availability, in: app)
        XCTAssertTrue(availability.label.contains("not enabled")); capture(app, "Arrangement-disabled-capability"); app.terminate()
    }
}
