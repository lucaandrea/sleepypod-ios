import XCTest

@MainActor final class PersonalJournalUITests: XCTestCase {
    private func launch(_ mode: String = "ready", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--personal-journal-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 40 }
        for _ in 0..<40 {
            if visible() { break }
            let upward = element.exists ? element.frame.midY > app.frame.maxY - 40 : !towardTop
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func open(_ app: XCUIApplication) {
        let link = app.buttons["personalJournal.accountLink"]; reveal(link, in: app); link.tap()
        XCTAssertTrue(app.navigationBars["Morning check-in"].waitForExistence(timeout: 10))
    }
    private func choose(_ identifier: String, value: String, in app: XCUIApplication) {
        let picker = app.buttons[identifier]; reveal(picker, in: app); picker.tap()
        let choice = app.buttons[value].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
    }
    func testExplicitRatingsSaveUnsavedStateAndReviewedDeletion() {
        let app = launch("empty"); open(app)
        let save = app.buttons["personalJournal.save"]; reveal(save, in: app); XCTAssertFalse(save.isEnabled)
        reveal(app.staticTexts["personalJournal.savedState"], in: app, towardTop: true); capture("Journal-empty-light")
        choose("personalJournal.restfulness", value: "4 — Rested", in: app)
        choose("personalJournal.comfort", value: "Comfortable", in: app)
        reveal(save, in: app); XCTAssertTrue(save.isEnabled); save.tap()
        let notice = app.staticTexts["personalJournal.notice"]; XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("saved privately"))
        reveal(app.staticTexts["personalJournal.savedState"], in: app, towardTop: true); capture("Journal-saved-light")
        choose("personalJournal.restfulness", value: "5 — Very rested", in: app)
        let state = app.staticTexts["personalJournal.savedState"]; reveal(state, in: app, towardTop: true)
        XCTAssertTrue(state.label.contains("Unsaved changes")); capture("Journal-edited-saved-light")
        let remove = app.buttons["personalJournal.remove"]; reveal(remove, in: app); remove.tap()
        let keep = app.buttons["Keep check-in"]; XCTAssertTrue(keep.waitForExistence(timeout: 5)); capture("Journal-delete-review"); keep.tap()
        remove.tap(); app.buttons["Delete check-in"].tap()
        reveal(notice, in: app, towardTop: true); XCTAssertTrue(notice.label.contains("removed"))
        reveal(save, in: app); XCTAssertFalse(remove.exists); XCTAssertFalse(save.isEnabled); app.terminate()
    }
    func testUncertainSaveRecoversWithoutEditingAndBackgroundHidesContent() {
        let app = launch("uncertain"); open(app)
        choose("personalJournal.restfulness", value: "5 — Very rested", in: app)
        let save = app.buttons["personalJournal.save"]; reveal(save, in: app); save.tap()
        let error = app.staticTexts["personalJournal.error"]; reveal(error, in: app, towardTop: true)
        XCTAssertTrue(error.label.contains("not confirmed")); capture("Journal-uncertain-light")
        let reconcile = app.buttons["personalJournal.reconcile"]; reveal(reconcile, in: app); reconcile.tap()
        let notice = app.staticTexts["personalJournal.notice"]; XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("saved privately"))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertFalse(app.navigationBars["Morning check-in"].exists)
        XCTAssertFalse(app.textFields["personalJournal.notes"].exists); app.terminate()
    }
    func testUnavailableAndFailedReadsGiveRecovery() {
        var app = launch("disabled")
        let link = app.buttons["personalJournal.accountLink"]; reveal(link, in: app); XCTAssertFalse(link.isEnabled)
        capture("Journal-unavailable-light"); app.terminate()
        app = launch("error"); open(app)
        let error = app.staticTexts["personalJournal.error"]; reveal(error, in: app, towardTop: true); XCTAssertTrue(error.label.contains("could not be verified"))
        let reopen = app.buttons["personalJournal.open"]; reveal(reopen, in: app); XCTAssertTrue(reopen.isEnabled)
        capture("Journal-read-error-light"); app.terminate()
    }
    func testOptionalContextLargestTextAndTabletLandscape() {
        let app = launch(large: true); open(app)
        let state = app.staticTexts["personalJournal.savedState"]; reveal(state, in: app); capture("Journal-dark-largest-text")
        let context = app.buttons["personalJournal.context"]; reveal(context, in: app); context.tap()
        let caffeine = app.buttons["journal.context.caffeine.status"]; reveal(caffeine, in: app)
        XCTAssertTrue(caffeine.label.contains("None")); capture("Journal-context-dark-largest-text")
        let save = app.buttons["personalJournal.save"]; reveal(save, in: app); XCTAssertFalse(save.isEnabled)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft; reveal(save, in: app); capture("Journal-tablet-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        app.terminate()
    }
}
