import XCTest

@MainActor final class PersonalLearningRemovalUITests: XCTestCase {
    private let archiveId = "30000000-0000-4000-8000-000000000001"
    private let recordId = "30000000-0000-4000-8000-000000000002"
    private func launch(_ mode: String = "ready", large: Bool = false, landscape: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--learning-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.frame.width > app.frame.height, landscape)
        tap(app.buttons["learning.accountLink"], in: app)
        tap(app.buttons["learning.archive.\(archiveId)"], in: app)
        tap(app.buttons["learning.record.\(recordId)"], in: app)
        XCTAssertTrue(app.staticTexts["learning.note"].waitForExistence(timeout: 10))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.frame
        for _ in 0..<30 {
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists, element.isHittable, frame.midY > window.minY + 110, frame.midY < window.maxY - 50 {
                XCTAssertGreaterThanOrEqual(frame.minX, window.minX); XCTAssertLessThanOrEqual(frame.maxX, window.maxX)
                return
            }
            let upward = !exists || frame.midY > window.maxY - 50
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.28 : 0.78)))
        }
        XCTFail("Unreachable \(element.identifier)")
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44); element.tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testReviewCancelThenConfirmPreservesScopeAndUpdatesRecordList() {
        let app = launch()
        tap(app.buttons["learning.reviewRemoval"], in: app)
        reveal(app.staticTexts["learning.removalBoundary"], in: app); capture("Removal-review-light")
        reveal(app.buttons["learning.cancelRemoval"], in: app); capture("Removal-review-both-choices")
        tap(app.buttons["learning.cancelRemoval"], in: app)
        XCTAssertFalse(app.staticTexts["learning.removalConfirmed"].exists)
        reveal(app.staticTexts["learning.note"], in: app); capture("Removal-cancelled-content-retained")
        tap(app.buttons["learning.reviewRemoval"], in: app)
        tap(app.buttons["learning.confirmRemoval"], in: app)
        XCTAssertTrue(app.staticTexts["learning.removalConfirmed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["learning.note"].exists); XCTAssertFalse(app.buttons["learning.export"].exists)
        reveal(app.staticTexts["learning.removalBoundary"], in: app); capture("Removal-confirmed-light")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let record = app.buttons["learning.record.\(recordId)"]
        reveal(record, in: app); XCTAssertTrue(record.label.contains("Content removed")); capture("Removal-record-list")
        record.tap(); XCTAssertTrue(app.staticTexts["learning.removed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["learning.reviewRemoval"].exists); app.terminate()
    }
    func testLostReplyRecoversByReadingReceiptAndDoesNotOfferResend() {
        let app = launch("removal-uncertain")
        tap(app.buttons["learning.reviewRemoval"], in: app); tap(app.buttons["learning.confirmRemoval"], in: app)
        let check = app.buttons["learning.checkRemoval"]
        reveal(check, in: app); capture("Removal-uncertain-light")
        XCTAssertFalse(app.buttons["learning.confirmRemoval"].exists); XCTAssertFalse(app.staticTexts["learning.note"].exists)
        check.tap(); XCTAssertTrue(app.staticTexts["learning.removalConfirmed"].waitForExistence(timeout: 10))
        capture("Removal-recovered-receipt"); app.terminate()
    }
    func testNoReceiptKeepsUnknownStateAndUnavailableControllerKeepsReading() {
        var app = launch("removal-pending")
        tap(app.buttons["learning.reviewRemoval"], in: app); tap(app.buttons["learning.confirmRemoval"], in: app)
        tap(app.buttons["learning.checkRemoval"], in: app)
        XCTAssertFalse(app.staticTexts["learning.removalConfirmed"].exists)
        reveal(app.staticTexts["learning.error"], in: app); capture("Removal-receipt-not-yet-found")
        app.terminate()
        app = launch("removal-readonly")
        XCTAssertFalse(app.buttons["learning.reviewRemoval"].exists)
        XCTAssertTrue(app.staticTexts["learning.note"].exists); app.terminate()
    }
    func testLargestTextKeepsReviewBoundariesAndBothChoicesReadable() {
        let app = launch("ready", large: true)
        tap(app.buttons["learning.reviewRemoval"], in: app)
        reveal(app.staticTexts["learning.removalRecord"], in: app); capture("Removal-review-large-context")
        reveal(app.staticTexts["learning.removalBoundary"], in: app); capture("Removal-review-large-boundary")
        reveal(app.buttons["learning.confirmRemoval"], in: app); capture("Removal-review-large-confirm")
        tap(app.buttons["learning.cancelRemoval"], in: app)
        reveal(app.buttons["learning.reviewRemoval"], in: app); capture("Removal-large-cancelled")
        app.terminate()
    }
    func testPendingRequestHidesContentAndDisablesReceiptCheck() {
        let app = launch("removal-busy")
        tap(app.buttons["learning.reviewRemoval"], in: app); tap(app.buttons["learning.confirmRemoval"], in: app)
        let loading = app.descendants(matching: .any).matching(identifier: "learning.loading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["learning.note"].exists)
        XCTAssertFalse(app.buttons["learning.checkRemoval"].isEnabled)
        capture("Removal-pending-request")
        XCTAssertTrue(app.staticTexts["learning.removalConfirmed"].waitForExistence(timeout: 15))
        app.terminate()
    }
    func testTabletLandscapeRemovalReceipt() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Landscape is an iPad acceptance check") }
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(landscape: true)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        tap(app.buttons["learning.reviewRemoval"], in: app)
        reveal(app.staticTexts["learning.removalBoundary"], in: app); capture("Removal-review-landscape")
        tap(app.buttons["learning.confirmRemoval"], in: app)
        XCTAssertTrue(app.staticTexts["learning.removalConfirmed"].waitForExistence(timeout: 10))
        capture("Removal-confirmed-landscape"); app.terminate()
    }
}
