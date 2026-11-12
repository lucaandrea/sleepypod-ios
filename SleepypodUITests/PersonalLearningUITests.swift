import XCTest

@MainActor final class PersonalLearningUITests: XCTestCase {
    private let archiveId = "30000000-0000-4000-8000-000000000001"
    private let recordId = "30000000-0000-4000-8000-000000000002"
    private func launch(_ mode: String = "ready", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--learning-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20)); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 40 }
        for _ in 0..<40 {
            if visible() { break }
            let upward = !element.exists || element.frame.midY > app.frame.maxY - 40
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func openLibrary(_ app: XCUIApplication) {
        let link = app.buttons["learning.accountLink"]; reveal(link, in: app); link.tap()
        XCTAssertTrue(app.navigationBars["Saved learning"].waitForExistence(timeout: 10))
    }
    private func openDetail(_ app: XCUIApplication) {
        openLibrary(app)
        let archive = app.buttons["learning.archive.\(archiveId)"]; reveal(archive, in: app); archive.tap()
        let record = app.buttons["learning.record.\(recordId)"]; reveal(record, in: app)
        XCTAssertTrue(record.label.contains("Journal entry")); record.tap()
        XCTAssertTrue(app.staticTexts["learning.note"].waitForExistence(timeout: 10))
    }
    func testLibraryJournalOriginalSourceAndCancelledExport() {
        let app = launch(); openLibrary(app); capture(app, "Learning-library-light")
        let archive = app.buttons["learning.archive.\(archiveId)"]; reveal(archive, in: app); archive.tap()
        let record = app.buttons["learning.record.\(recordId)"]; reveal(record, in: app); capture(app, "Learning-records-light"); record.tap()
        let note = app.staticTexts["learning.note"]; reveal(note, in: app)
        XCTAssertEqual(note.label, "Felt comfortable after an earlier bedtime."); capture(app, "Learning-journal-light")
        let source = app.buttons["Source and original file"]; reveal(source, in: app); source.tap()
        let export = app.buttons["learning.export"]; reveal(export, in: app); capture(app, "Learning-source-light"); export.tap()
        let save = app.buttons["Save"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            save.exists && save.isHittable && app.frame.contains(save.frame)
        }, object: nil)
        // The hosted simulator's first Files launch can exceed ten seconds. Still
        // require the real, hittable Save control before testing cancellation.
        let pickerResult = XCTWaiter.wait(for: [ready], timeout: 30)
        capture(app, "Learning-export-destination")
        if pickerResult != .completed { print(app.debugDescription) }
        XCTAssertEqual(pickerResult, .completed)
        cancelExport(in: app)
        XCTAssertTrue(app.navigationBars["Saved record"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["learning.exportNotice"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(record, in: app); XCTAssertFalse(app.staticTexts["learning.note"].exists)
        record.tap(); XCTAssertTrue(note.waitForExistence(timeout: 10)); app.terminate()
    }
    private func cancelExport(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        // Files may restore a nested folder. Its root exposes the explicit Cancel action.
        let browser = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        for _ in 0..<3 {
            if cancel.exists && cancel.isHittable { break }
            let back = browser.buttons["BackButton"]
            guard back.exists && back.isHittable else { break }
            back.tap()
        }
        capture(app, "Learning-export-cancellation")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
    }
    func testEmptyAndUnavailableLibrariesExplainWhatToDo() {
        var app = launch("empty"); openLibrary(app)
        let empty = app.staticTexts["learning.empty"]; reveal(empty, in: app); capture(app, "Learning-empty-light")
        XCTAssertFalse(app.buttons["learning.older"].exists); app.terminate()
        app = launch("disabled")
        let link = app.buttons["learning.accountLink"]; reveal(link, in: app); XCTAssertFalse(link.isEnabled)
        let availability = app.staticTexts["learning.availability"]; reveal(availability, in: app)
        XCTAssertTrue(availability.label.contains("not enabled")); capture(app, "Learning-unavailable-light"); app.terminate()
    }
    func testFailedReadWithdrawsContentAndKeepsReloadAvailable() {
        let app = launch("error"); openLibrary(app)
        let error = app.staticTexts["learning.error"]; reveal(error, in: app)
        XCTAssertTrue(error.label.contains("could not be verified")); XCTAssertFalse(app.buttons["learning.archive.\(archiveId)"].exists)
        let reload = app.buttons["learning.reload"]; reveal(reload, in: app); XCTAssertTrue(reload.isEnabled)
        capture(app, "Learning-read-error-light"); reload.tap(); XCTAssertTrue(error.waitForExistence(timeout: 10)); app.terminate()
    }
    func testLargestTextKeepsJournalAndSourceControlsReachable() {
        let app = launch("ready", large: true); openDetail(app)
        let note = app.staticTexts["learning.note"]; reveal(note, in: app); capture(app, "Learning-journal-dark-largest-text")
        let source = app.buttons["Source and original file"]; reveal(source, in: app); source.tap()
        let export = app.buttons["learning.export"]; reveal(export, in: app); capture(app, "Learning-source-dark-largest-text")
        XCTAssertTrue(export.isEnabled); app.terminate()
    }
    func testBackgroundClearsDetailAndReturnsToFreshPersonalAccount() {
        let app = launch(); openDetail(app)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.navigationBars["Personal account"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["learning.note"].exists)
        openDetail(app); XCTAssertTrue(app.staticTexts["learning.note"].exists); app.terminate()
    }
    func testTabletLandscapeKeepsRecordAndSourceReachable() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Landscape is supported on iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(); openDetail(app)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        let note = app.staticTexts["learning.note"]; reveal(note, in: app); capture(app, "Learning-journal-landscape-light")
        let source = app.buttons["Source and original file"]; reveal(source, in: app); source.tap()
        let export = app.buttons["learning.export"]; reveal(export, in: app); capture(app, "Learning-source-landscape-light")
        XCTAssertTrue(export.isEnabled); app.terminate()
    }
}
