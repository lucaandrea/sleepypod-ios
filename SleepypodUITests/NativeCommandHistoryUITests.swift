import XCTest
import UIKit

@MainActor final class NativeCommandHistoryUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings", "-uiCommandHistoryScenario", scenario,
            "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let row = app.buttons["settings.commandHistory"]; reveal(row, app); row.tap()
        XCTAssertTrue(app.navigationBars["Command history"].waitForExistence(timeout: 5)); return app
    }
    func testReceiptStatesReviewAndReadbackStayDistinct() {
        let app = launch("states")
        XCTAssertTrue(app.staticTexts["SYNTHETIC COMMAND EXAMPLES"].waitForExistence(timeout: 3))
        capture(app, "Commands-unknown")
        let review = app.buttons.matching(identifier: "commandHistory.review.base.stop").firstMatch
        reveal(review, app); review.tap()
        XCTAssertTrue(app.buttons["I checked the bed"].waitForExistence(timeout: 3)); capture(app, "Commands-review")
        app.buttons["I checked the bed"].tap()
        let reviewed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reviewed ")).firstMatch
        reveal(reviewed, app, searchUp: true); XCTAssertTrue(app.staticTexts["UNKNOWN"].exists); capture(app, "Commands-reviewed")
        for state in ["EXECUTING", "NOT DISPATCHED", "REJECTED", "EXPIRED", "ACKNOWLEDGED"] { reveal(app.staticTexts[state], app); capture(app, "Commands-\(state.lowercased().replacingOccurrences(of: " ", with: "-"))") }
        app.terminate()
        let recovered = launch("readback"), refresh = recovered.buttons["commandHistory.refresh.base.stop"]
        reveal(refresh, recovered); refresh.tap()
        reveal(recovered.staticTexts["ACKNOWLEDGED"], recovered, searchUp: true)
        XCTAssertFalse(recovered.buttons["commandHistory.review.base.stop"].exists); capture(recovered, "Commands-readback")
    }
    func testOfflineAndOrdinaryDemoDoNotInventReceipts() {
        let app = launch("offline"), refresh = app.buttons["commandHistory.refresh.base.stop"]
        reveal(refresh, app); refresh.tap(); reveal(app.staticTexts["commandHistory.error"], app, searchUp: true)
        XCTAssertTrue(app.staticTexts["UNKNOWN"].exists); capture(app, "Commands-offline"); app.terminate()
        let empty = launch("normal"); XCTAssertTrue(empty.staticTexts["No commands yet"].waitForExistence(timeout: 3)); capture(empty, "Commands-empty")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, searchUp: Bool = false) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<26 {
            if element.exists && element.isHittable && element.frame.midY > 115 && element.frame.midY < app.frame.height - 90 { return }
            let up = searchUp && (!element.exists || element.frame.midY < 115)
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.3 : 0.73)).press(forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: up ? 0.73 : 0.3)))
        }
        XCTFail("Control not reachable: \(element)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
