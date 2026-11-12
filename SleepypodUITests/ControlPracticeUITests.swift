import XCTest

@MainActor final class ControlPracticeUITests: XCTestCase {
    private func launch(_ mode: String = "personal", large: Bool = false, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
                               "-appearance", (large || dark) ? "Dark" : "Light"]
        if mode == "personal" { app.launchArguments += ["--household-fixture"] }
        else if mode == "join" { app.launchArguments += ["--household-join-fixture"] }
        else { app.launchArguments += ["-uiRoute", "settings", "-household.personalWorkspaceActive", "NO"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        func bounds() -> CGRect {
            let joining = app.descendants(matching: .any)["household.joinForm"].firstMatch
            let practice = app.descendants(matching: .any)["practice.form"].firstMatch
            let surface = joining.exists ? joining : practice.exists ? practice : app
            var frame = surface.frame.intersection(app.frame)
            let navigation = app.navigationBars.firstMatch
            if navigation.exists { let top = max(frame.minY, navigation.frame.maxY + 5); frame.size.height = max(0, frame.maxY - top); frame.origin.y = top }
            if app.keyboards.firstMatch.exists { frame.size.height = max(0, min(frame.maxY, app.keyboards.firstMatch.frame.minY - 5) - frame.minY) }
            return frame.insetBy(dx: 0, dy: 8)
        }
        func visible() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let viewport = bounds(), control = element.frame
            // Keep the whole control visible when it fits, including multi-line Stop buttons.
            if control.height <= viewport.height { return viewport.contains(control) }
            return viewport.contains(CGPoint(x: control.midX, y: control.midY))
        }
        for _ in 0..<35 {
            if visible() { break }
            let frame = bounds(), upward = element.exists ? element.frame.maxY > bounds().maxY : !towardTop
            let start = CGPoint(x: frame.minX + frame.width * 0.9, y: frame.minY + frame.height * (upward ? 0.78 : 0.28))
            let finish = CGPoint(x: start.x, y: frame.minY + frame.height * (upward ? 0.28 : 0.78))
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: start.x, dy: start.y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: finish.x, dy: finish.y)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func tap(_ id: String, in app: XCUIApplication) { let button = app.buttons[id]; reveal(button, in: app); button.tap() }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func practice(_ app: XCUIApplication, owner: Bool = false) {
        let entry = app.buttons[owner ? "settings.practice" : "household.practice"]
        if !owner { XCTAssertTrue(app.navigationBars["Personal account"].waitForExistence(timeout: 20)) }
        else { XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20)) }
        reveal(entry, in: app); entry.tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
    }
    func testPersonalJourneyRequestsReviewsStopsAndReturns() {
        let app = launch(); practice(app); capture("Practice-temperature-light")
        tap("practice.cooler", in: app)
        XCTAssertEqual(app.staticTexts["practice.requestedTarget"].label, "75°F")
        XCTAssertFalse(app.buttons["practice.apply"].exists)
        reveal(app.staticTexts["practice.feedback"], in: app); capture("Practice-temperature-requested-light")
        tap("practice.next", in: app); capture("Practice-wake-light")
        XCTAssertFalse(app.buttons["practice.save"].exists); tap("practice.review", in: app)
        XCTAssertTrue(app.staticTexts["Warming starts at 07:30"].exists)
        reveal(app.buttons["practice.save"], in: app); capture("Practice-wake-review-light")
        XCTAssertTrue(app.staticTexts["Vibration at 08:00 · 20 seconds"].exists)
        XCTAssertTrue(app.staticTexts["Regular week: still 07:00"].exists)
        XCTAssertTrue(app.buttons["practice.save"].isEnabled); app.buttons["practice.save"].tap()
        tap("practice.next", in: app)
        XCTAssertEqual(app.buttons["practice.stopTemperature"].label, "Power off")
        tap("practice.stopTemperature", in: app)
        XCTAssertEqual(app.staticTexts["practice.temperatureState"].label, "Example temperature: Off")
        XCTAssertEqual(app.staticTexts["practice.vibrationState"].label, "Example vibration: Playing")
        capture("Practice-temperature-off-light")
        XCTAssertEqual(app.buttons["practice.stopVibration"].label, "Stop vibration")
        tap("practice.stopVibration", in: app)
        XCTAssertEqual(app.staticTexts["practice.vibrationState"].label, "Example vibration: Stopped")
        capture("Practice-vibration-stopped-light")
        XCTAssertTrue(app.staticTexts["practice.nextAlarm"].label.contains("08:00"))
        let progress = app.staticTexts["practice.progress"]; reveal(progress, in: app)
        XCTAssertEqual(progress.label, "3 of 3 actions practiced"); capture("Practice-complete-light")
        tap("practice.finish", in: app); XCTAssertTrue(app.buttons["household.practice"].waitForExistence(timeout: 5))
        practice(app); XCTAssertEqual(app.staticTexts["practice.requestedTarget"].label, "76°F"); app.terminate()
    }
    func testOwnerEntryAndSkippedLessonDoNotBecomeCompletion() {
        let app = launch("owner"); practice(app, owner: true)
        reveal(app.staticTexts["practice.heading"], in: app); capture("Practice-owner-entry")
        tap("practice.next", in: app); tap("practice.next", in: app)
        let progress = app.staticTexts["practice.progress"]; reveal(progress, in: app); XCTAssertEqual(progress.label, "0 of 3 actions practiced")
        tap("practice.reset", in: app)
        reveal(app.staticTexts["practice.heading"], in: app)
        XCTAssertTrue(app.staticTexts["practice.heading"].label.contains("cooler"))
        capture("Practice-owner-reset"); app.terminate()
    }
    func testLargestTextDarkKeepsActionsAndLandscapeReachable() {
        let app = launch(large: true); practice(app); capture("Practice-largest-text-dark")
        tap("practice.cooler", in: app)
        XCTAssertEqual(app.staticTexts["practice.requestedTarget"].label, "75°F")
        reveal(app.staticTexts["practice.feedback"], in: app); capture("Practice-temperature-requested-dark")
        tap("practice.next", in: app); tap("practice.review", in: app)
        reveal(app.staticTexts["Warming starts at 07:30"], in: app)
        capture("Practice-warming-largest-text-dark")
        reveal(app.buttons["practice.save"], in: app); capture("Practice-review-largest-text-dark")
        app.buttons["practice.save"].tap(); tap("practice.next", in: app)
        reveal(app.buttons["practice.stopVibration"], in: app); capture("Practice-vibration-control-largest-text-dark")
        tap("practice.stopVibration", in: app)
        reveal(app.buttons["practice.stopTemperature"], in: app); capture("Practice-temperature-stop-largest-text-dark")
        tap("practice.stopTemperature", in: app)
        reveal(app.staticTexts["practice.progress"], in: app); capture("Practice-stop-largest-text-dark")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            reveal(app.buttons["practice.finish"], in: app); XCTAssertGreaterThan(app.frame.width, app.frame.height)
            capture("Practice-ipad-landscape"); XCUIDevice.shared.orientation = .portrait
        }
        tap("practice.reset", in: app)
        reveal(app.staticTexts["practice.heading"], in: app)
        XCTAssertTrue(app.staticTexts["practice.heading"].label.contains("cooler")); app.terminate()
    }
    func testOwnerDarkSheetKeepsInstructionsReadable() {
        let app = launch("owner", dark: true); practice(app, owner: true)
        reveal(app.staticTexts["practice.heading"], in: app); capture("Practice-owner-entry-dark")
        tap("practice.cooler", in: app)
        XCTAssertEqual(app.staticTexts["practice.requestedTarget"].label, "75°F")
        reveal(app.staticTexts["practice.feedback"], in: app); capture("Practice-owner-requested-dark")
        app.terminate()
    }
    func testInvitationReviewRejectsBadLinkAndClearsWhenBackgrounded() {
        let app = launch("join"); tapJoin(app)
        let field = app.secureTextFields["household.invitationLink"]; field.tap(); field.typeText("not-a-link\n")
        tap("household.reviewInvitation", in: app)
        reveal(app.staticTexts["household.invitationError"], in: app)
        XCTAssertTrue(app.staticTexts["household.invitationError"].exists); capture("Invitation-invalid")
        reveal(field, in: app, towardTop: true); field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        field.typeText(exampleInvitation + "\n"); tap("household.reviewInvitation", in: app)
        let origin = app.staticTexts["household.invitationOrigin"]; reveal(origin, in: app)
        XCTAssertEqual(origin.label, "https://bed.example.com"); capture("Invitation-reviewed")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", String(repeating: "A", count: 43))).firstMatch.exists)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertFalse(origin.exists)
        reveal(app.buttons["household.joinSubmit"], in: app)
        XCTAssertFalse(app.buttons["household.joinSubmit"].isEnabled); app.terminate()
    }
    func testExpiredInvitationReportsRecoveryWithoutOpeningOwnerControls() {
        let app = launch("join", large: true); tapJoin(app)
        let field = app.secureTextFields["household.invitationLink"]; reveal(field, in: app); field.tap(); field.typeText(exampleInvitation + "\n")
        tap("household.reviewInvitation", in: app)
        let origin = app.staticTexts["household.invitationOrigin"]; reveal(origin, in: app)
        XCTAssertEqual(origin.label, "https://bed.example.com")
        let name = app.textFields["household.name"]; reveal(name, in: app); name.tap(); name.typeText("Example sleeper\n")
        let acknowledgment = app.switches["household.joinAcknowledgment"]; reveal(acknowledgment, in: app)
        // At accessibility sizes the label spans the row; tap the visible switch thumb.
        acknowledgment.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(acknowledgment.value as? String, "1", "The account acknowledgment must be selected before Join")
        let submit = app.buttons["household.joinSubmit"]; reveal(submit, in: app); capture("Invitation-ready-largest-text")
        if !submit.isEnabled { add(XCTAttachment(string: app.debugDescription)) }
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.staticTexts["household.joinError"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["household.joinError"], in: app); XCTAssertTrue(app.staticTexts["household.joinError"].label.contains("new invitation"))
        XCTAssertFalse(app.tabBars.firstMatch.exists); capture("Invitation-expired-largest-text"); app.terminate()
    }
    private var exampleInvitation: String { "https://bed.example.com/household/index.html#invite=" + String(repeating: "A", count: 43) }
    private func tapJoin(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Personal account"].waitForExistence(timeout: 20)); tap("household.join", in: app)
        XCTAssertTrue(app.navigationBars["Join account"].waitForExistence(timeout: 5)); capture("Invitation-entry")
    }
}
