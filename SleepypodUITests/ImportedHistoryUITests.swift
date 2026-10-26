import XCTest
import UIKit

@MainActor final class ImportedHistoryUITests: XCTestCase {
    private func launch(_ scenario: String = "example") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "sleep", "-uiHistoryScenario", scenario, "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.buttons["Sleep options"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Edit times"].waitForExistence(timeout: 10))
        app.buttons["Sleep options"].tap()
        if app.buttons["Personal tools"].exists { app.buttons["Personal tools"].tap() }
        let destination = app.buttons["Imported history"]
        for _ in 0..<8 {
            if destination.exists && destination.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(destination.isHittable); destination.tap()
        XCTAssertTrue(app.buttons["history.reload"].waitForExistence(timeout: 8)); return app
    }
    func testSourcePagingPresenceClaimsAndAllRecordTypes() {
        let app = launch(); capture(app, "History-source")
        let source = app.buttons["Source details"]; reveal(source, app); source.tap(); capture(app, "History-provenance"); source.tap()
        let apply = app.buttons["history.apply"]; reveal(app.segmentedControls["history.side"], app)
        app.segmentedControls["history.side"].buttons["Left"].tap(); reveal(apply, app); apply.tap()
        let presence = app.buttons["history.presence.2"]; reveal(presence, app)
        capture(app, "History-presence-first"); presence.tap()
        XCTAssertTrue(app.navigationBars["Presence record"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["Present intervals"], app); capture(app, "History-present-claim")
        reveal(app.staticTexts["Absent intervals"], app); capture(app, "History-absent-claim")
        let original = app.buttons["Original interval text"]; reveal(original, app); original.tap(); capture(app, "History-original-intervals")
        app.navigationBars.buttons["Done"].tap()
        let more = app.buttons["history.more"]; reveal(more, app); more.tap()
        reveal(app.buttons["history.presence.1"], app); capture(app, "History-presence-next")
        XCTAssertFalse(more.exists)
        selectKind("Vitals", app); reveal(apply, app); apply.tap()
        reveal(app.staticTexts["HRV estimate"].firstMatch, app); capture(app, "History-vitals")
        reveal(app.staticTexts["Unavailable"].firstMatch, app)
        selectKind("Movement", app); reveal(apply, app); apply.tap()
        reveal(app.staticTexts["Original total"].firstMatch, app); capture(app, "History-movement")
        reveal(app.segmentedControls["history.side"], app); app.segmentedControls["history.side"].buttons["Right"].tap()
        reveal(apply, app); apply.tap(); XCTAssertTrue(app.staticTexts["history.emptyRange"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["history.emptyRange"], app); capture(app, "History-empty-side")
    }
    func testNoArchiveOfflineAndChangedArchiveRemainDistinct() {
        let empty = launch("empty")
        XCTAssertTrue(empty.staticTexts["No imported history"].waitForExistence(timeout: 5)); XCTAssertFalse(empty.buttons["history.apply"].exists)
        capture(empty, "History-not-imported"); empty.terminate()
        let offline = launch("offline")
        XCTAssertTrue(offline.staticTexts["history.error"].waitForExistence(timeout: 5)); XCTAssertFalse(offline.staticTexts["No imported history"].exists)
        capture(offline, "History-offline"); offline.terminate()
        let changed = launch("changed"), apply = changed.buttons["history.apply"]; reveal(apply, changed); apply.tap()
        XCTAssertTrue(changed.staticTexts["history.error"].waitForExistence(timeout: 5))
        XCTAssertFalse(changed.buttons["history.apply"].exists); capture(changed, "History-source-changed")
    }
    func testSettingsUsesTheSameReadOnlyArchiveDestination() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "allsettings", "-uiHistoryScenario", "empty", "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let destination = app.buttons["Imported history"]
        for _ in 0..<30 { if destination.exists && destination.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(destination.isHittable); destination.tap()
        XCTAssertTrue(app.navigationBars["Imported history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No imported history"].waitForExistence(timeout: 5))
        capture(app, "History-from-settings")
    }
    private func selectKind(_ title: String, _ app: XCUIApplication) {
        let picker = app.buttons["history.kind"]; reveal(picker, app); picker.tap(); app.buttons[title].tap()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<45 {
            let scroll = app.navigationBars["Presence record"].exists ? app.scrollViews["history.presence.scroll"] : app.scrollViews["history.scroll"]
            let bounds = scroll.frame.intersection(app.frame), top = max(bounds.minY + 12, app.navigationBars.firstMatch.frame.maxY + 12)
            let frame = element.exists ? element.frame : .zero
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 20))
            if element.exists, element.isHittable, visible.contains(frame) || (frame.height > visible.height && frame.minY >= visible.minY && visible.intersects(frame)) { return }
            let direction = frame.isEmpty || frame.midY >= visible.midY ? 1.0 : -1.0
            let distance = min(0.4, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) { let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}
