import XCTest

@MainActor final class ComfortOwnerUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "comfort",
                               "-uiComfortExample", "NO", "-uiComfortOwnerScenario", scenario, "-appearance", "Dark"]
        app.launch()
        let sides = app.segmentedControls["comfort.side"]
        XCTAssertTrue(sides.waitForExistence(timeout: 15)); sides.buttons.element(boundBy: 0).tap()
        let open = app.buttons["comfort.owner.open"]; reveal(open, app); open.tap()
        XCTAssertTrue(app.buttons["comfort.owner.refresh"].waitForExistence(timeout: 10)); return app
    }
    func testAttendedEvidenceIsSeparateAndDemoCannotConfirm() {
        let app = launch("initial"); capture(app, "Owner-overview")
        let inspect = app.buttons["comfort.owner.inspect"]; reveal(inspect, app); capture(app, "Owner-checks"); inspect.tap()
        XCTAssertTrue(app.navigationBars["Owner review"].waitForExistence(timeout: 5)); capture(app, "Owner-evidence")
        let confirm = app.buttons["comfort.owner.confirm"]; reveal(confirm, app)
        XCTAssertFalse(confirm.isEnabled); XCTAssertFalse(app.switches["comfort.owner.consent"].isEnabled)
        capture(app, "Owner-consent-disabled")
        app.buttons["Cancel"].tap(); XCTAssertTrue(app.buttons["comfort.owner.refresh"].waitForExistence(timeout: 5))
    }
    func testActivationAndRecoveryExposeTheirExactEvidence() {
        let app = launch("ready")
        let activate = app.buttons["comfort.owner.activate"]; reveal(activate, app); activate.tap()
        XCTAssertTrue(app.navigationBars["Owner review"].waitForExistence(timeout: 5)); capture(app, "Owner-activation")
        let nights = app.scrollViews["comfort.owner.review.scroll"].buttons["comfort.owner.nights"]
        reveal(nights, app); nights.tap()
        XCTAssertTrue(app.staticTexts["2026-11-04"].exists); capture(app, "Owner-night-details"); nights.tap()
        let consent = app.switches["comfort.owner.consent"]; reveal(consent, app)
        XCTAssertFalse(consent.isEnabled); capture(app, "Owner-activation-nights")
        app.terminate()
        let recovery = launch("uncertain"), inspect = recovery.buttons["comfort.owner.recover"]
        reveal(inspect, recovery); capture(recovery, "Owner-uncertain"); inspect.tap()
        XCTAssertTrue(recovery.navigationBars["Owner review"].waitForExistence(timeout: 5))
        reveal(recovery.staticTexts["Preserve the uncertain outcome"], recovery); capture(recovery, "Owner-recovery")
        let confirm = recovery.buttons["comfort.owner.confirm"]; reveal(confirm, recovery); XCTAssertFalse(confirm.isEnabled)
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 15)
        for _ in 0..<45 {
            let reviewScroll = app.scrollViews["comfort.owner.review.scroll"], ownerScroll = app.scrollViews["comfort.owner.scroll"]
            let scroll = reviewScroll.exists ? reviewScroll : ownerScroll.exists ? ownerScroll : app.scrollViews.firstMatch
            let bounds = scroll.frame.intersection(app.frame)
            let navigation = app.navigationBars["Owner review"].exists ? app.navigationBars["Owner review"] : app.navigationBars.firstMatch
            let top = max(bounds.minY + 12, navigation.frame.maxY + 12)
            let frame = element.exists ? element.frame : .zero
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 20))
            if element.exists, element.isHittable, visible.contains(frame) || frame.height > visible.height && visible.intersection(frame).height > 100 { return }
            let direction = frame.isEmpty || frame.midY >= visible.midY ? 1.0 : -1.0
            let distance = min(0.4, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
